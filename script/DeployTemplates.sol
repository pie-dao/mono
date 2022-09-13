// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.12;

pragma abicoder v2;

import "@std/console.sol";
import "@std/Script.sol";

import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";

import {AuxoTest} from "@hub-test/mocks/MockERC20.sol";
import {StargateRouterMock} from "@hub-test/mocks/MockStargateRouter.sol";
import {LZEndpointMock} from "@hub-test/mocks/MockLayerZeroEndpoint.sol";

import {XChainStrategy} from "@hub/strategy/XChainStrategy.sol";
import {XChainHub} from "@hub/XChainHub.sol";
import {XChainHubSingle} from "@hub/XChainHubSingle.sol";
import {Vault} from "@vaults/Vault.sol";
import {VaultFactory} from "@vaults/factory/VaultFactory.sol";
import {MultiRolesAuthority} from
    "@vaults/auth/authorities/MultiRolesAuthority.sol";
import {Authority} from "@vaults/auth/Auth.sol";

import {IVault} from "@interfaces/IVault.sol";
import {IStargateRouter} from "@interfaces/IStargateRouter.sol";
import {ILayerZeroEndpoint} from "@interfaces/ILayerZeroEndpoint.sol";
import {IHubPayload} from "@interfaces/IHubPayload.sol";

import "./Deployer.sol";
import "../utils/ChainConfig.sol";
import "./Env.s.sol";

/// @dev Configure here the shared logic for deploy scripts

contract Setup is Script, Env {
     ChainConfig network;

    /// *** SOURCE ***
    uint16 public srcChainId;
    ERC20 public srcToken;
    IStargateRouter public srcRouter;
    ILayerZeroEndpoint public srcLzEndpoint;
    Deployer public srcDeployer;
    VaultFactory public srcFactory;
    
    /// @dev you might need to update these addresses
    // Anvil unlocked account
    address public srcStrategist = 0xeB959af810FEC83dE7021A77906ab3d9fDe567B1;
    address public srcFeeCollector =
        payable(0xB50c633C6B0541ccCe0De36A57E7b30550CE51Ec);
    address public srcRefundAddress =
        payable(0xB50c633C6B0541ccCe0De36A57E7b30550CE51Ec);

    constructor(ChainConfig memory _network) {
        network = _network;
        srcChainId = network.id;
        srcToken = ERC20(network.usdc.addr);
        srcRouter = IStargateRouter(network.sg);
        srcLzEndpoint = ILayerZeroEndpoint(network.lz);
    }
}


abstract contract Deploy is Script, Env, Setup {

    function _runSetup() internal {
        vm.startBroadcast(srcGovernor);
        srcDeployer = deployAuthAndDeployerNoOwnershipTransfer(
            srcChainId,
            srcToken,
            srcRouter,
            network.lz,
            srcGovernor,
            srcStrategist
        );

        // initially deploy with a chainId of zero, this can be updated later
        deployVaultHubStrat(srcDeployer, 0, "TEST");
        vm.stopBroadcast();
    }
}

abstract contract DeployWithExistingVault is Script, Env, Setup {
    Deployer public oldDeployer;

    function _runSetup() internal {
        require(address(oldDeployer) != address(0), "SET OLD DEPLOYER");

        vm.startBroadcast(srcGovernor);

        /// @dev overloads vault factory
        srcDeployer = deployAuthAndDeployerNoOwnershipTransfer(
            srcChainId,
            srcToken,
            srcRouter,
            network.lz,
            srcGovernor,
            srcStrategist,
            oldDeployer.vaultFactory()
        );

        // initially deploy with a chainId of zero, this can be updated later
        deployHubStratConnectVault(
            srcDeployer, 
            0, 
            "TEST STRATEGY", 
            oldDeployer.vaultFactory(), 
            oldDeployer.vaultProxy()
        );
        vm.stopBroadcast();
    }
}


interface IMintable is IERC20 {
    function mint(address _to, uint256 _amount) external;
}

/// @notice DepositTest will mint tokens on test net for the account
abstract contract DepositTest is Script, Deploy {
    function depositToVault() public {
        uint256 balance = srcToken.balanceOf(msg.sender);
        uint256 baseUnit = 10 ** srcToken.decimals();
        Vault vault = srcDeployer.vaultProxy();
        if (balance < baseUnit * 1000) {
            // if no tokens, send a milly
            IMintable(address(srcToken)).mint(msg.sender, baseUnit * 1e6);
        }
        srcToken.approve(address(vault), type(uint256).max);
        if (vault.paused()) vault.triggerPause();
        vault.deposit(srcGovernor, 1e3 * baseUnit);
    }
}

/// @notice when depositing for real we need to set deposit amounts
abstract contract DepositProd is Script, Deploy {
    uint256 depositAmount;

    function depositToVault() public {
        require(depositAmount > 0, "depositToVault::setDepositAmount");
        Vault vault = srcDeployer.vaultProxy();
        srcToken.approve(address(vault), type(uint256).max);
        vault.deposit(depositor, depositAmount);

        console.log("Balance of Underlying:", srcToken.balanceOf(depositor));
        console.log("Balance of Vault:", vault.balanceOf(depositor));
    }
}

/// @dev this must be run for both single hubs along with preparing the dst vault
abstract contract PrepareXChainDeposit is Script, Deploy {
    ChainConfig public remote;
    address public remoteStrategy;

    function prepare() public {
        require(remoteStrategy != address(0), "INIT REMOTE STRAT");

        XChainHubSingle hub = XChainHubSingle(address(srcDeployer.hub()));
        Vault vault = srcDeployer.vaultProxy();

        // set the remote strategy for this hub
        hub.setStrategyForChain(remoteStrategy, remote.id);

        // update the strategy chain Id
        srcDeployer.strategy().setDestinationChainId(remote.id);
        
        // ensure the vault is trusted and set the local vault to be used for the remote chain
        hub.setTrustedVault(address(vault), true);
        hub.setVaultForChain(address(vault), remote.id);
        
        // set the local strategy on this chain
        hub.setTrustedStrategy(address(srcDeployer.strategy()), true);
        hub.setLocalStrategy(address(srcDeployer.strategy()));
    }
}

/// @dev I have separated the XChainStrategyDeposit into a separate step
abstract contract XChainDeposit is Script, Deploy {
    address public dstVault;
    address public dstHub;
    ChainConfig public dst;
    uint256 depositAmount;

    function deposit() public {
        require(srcDeployer.strategy().destinationChainId() != 0, "INIT DESTINATION CHAIN");
        require(dstVault != address(0), "INIT VAULT");
        require(dstHub != address(0), "INIT HUB");
        require(depositAmount != 0, "INIT DEPOSIT AMOUNT");

        // Slippage tolerance = 0.5%
        uint256 min = (depositAmount * 995) / 1000;

        // depositIntoStrategy(srcDeployer, depositAmount);

        XChainStrategy strategy = srcDeployer.strategy();

        IHubPayload.Message memory message = IHubPayload.Message({
            action: srcDeployer.hub().DEPOSIT_ACTION(),
            payload: abi.encode(
                IHubPayload.DepositPayload({
                    vault: dstVault,
                    strategy: address(strategy),
                    amountUnderyling: depositAmount
                })
                )
        });

        (uint256 feeEstimate,) = srcRouter.quoteLayerZeroFee(
            dst.id,
            1, // function type
            abi.encodePacked(dstHub), // where to go
            abi.encode(message), // payload
            IStargateRouter.lzTxObj({
                dstGasForCall: dstDefaultGas,
                dstNativeAmount: 0,
                dstNativeAddr: abi.encodePacked(address(0x0))
            })
        );
        console.log("Fee Estimate", feeEstimate);

        // if (feeEstimate > 0.1 ether) feeEstimate = 0.1 ether;

        strategy.depositUnderlying{value: feeEstimate}(
            XChainStrategy.DepositParams({
                amount: depositAmount,
                minAmount: min,
                srcPoolId: network.usdc.poolId,
                dstPoolId: dst.usdc.poolId,
                dstHub: dstHub,
                dstVault: dstVault,
                refundAddress: payable(srcGovernor),
                dstGas: dstDefaultGas
            })
        );
    }
}

abstract contract XChainReport is Script, Deploy {
    uint16[] chainsToReport;
    address[] strategiesToReport;
    address dstStrategy;
    ChainConfig dst;

    function _report() internal {
        require(dstStrategy != address(0x0), "XChainReport::SET STRATEGY");

        IHubPayload.Message memory message = IHubPayload.Message({
            action: srcDeployer.hub().REPORT_UNDERLYING_ACTION(),
            payload: abi.encode(
                IHubPayload.ReportUnderlyingPayload({
                    strategy: dstStrategy,
                    // uint for fee estimate only
                    amountToReport: type(uint256).max
                })
                )
        });

        bytes memory adapterParams = abi.encodePacked(
            uint16(1), // endpoint version
            uint256(dstDefaultGas) // gas (default)
        );

        (uint256 feeEstimate,) = ILayerZeroEndpoint(srcDeployer.lzEndpoint())
            .estimateFees(
            dst.id, // destination chain id
            address(srcDeployer.hub()), // address of *calling* contract
            abi.encode(message), // payload
            false, // pay in zro
            adapterParams
        );

        console.log("XChainReport::LayerZeroFeeEstimate:", feeEstimate);

        srcDeployer.hub().lz_reportUnderlying{value: feeEstimate}(
            IVault(address(srcDeployer.vaultProxy())),
            chainsToReport,
            strategiesToReport,
            dstDefaultGas,
            payable(srcRefundAddress)
        );
    }
}

abstract contract XChainRequestWithdraw is Script, Deploy {
    ChainConfig dst;
    address dstVault;

    function _request() internal {
        require(dstVault != address(0x0), "XChainReport::SET VAULT");

        XChainStrategy strategy = srcDeployer.strategy();

        IHubPayload.Message memory message = IHubPayload.Message({
            action: srcDeployer.hub().REPORT_UNDERLYING_ACTION(),
            payload: abi.encode(
                IHubPayload.RequestWithdrawPayload({
                    vault: dstVault,
                    strategy: address(strategy),
                    // uint for fee estimate only
                    amountVaultShares: type(uint256).max
                })
                )
        });

        bytes memory adapterParams = abi.encodePacked(
            uint16(1), // endpoint version
            uint256(dstDefaultGas) // gas (default)
        );

        (uint256 feeEstimate,) = ILayerZeroEndpoint(srcDeployer.lzEndpoint())
            .estimateFees(
            dst.id, // destination chain id
            address(srcDeployer.hub()), // address of *calling* contract
            abi.encode(message), // payload
            false, // pay in zro
            adapterParams
        );

        console.log(
            "XChainWithdrawalRequest::LayerZeroFeeEstimate:", feeEstimate
        );

        // added here as an explicit reminer that we request to withdraw shares
        // not underlying tokens, this happens to work in the case of an initial deposit
        // because the ER == 1
        uint exchangeRate = 1;

        strategy.startRequestToWithdrawUnderlying{value: feeEstimate}(
            strategy.xChainReported() * exchangeRate,
            dstDefaultGas,
            payable(srcDeployer.refundAddress()),
            dstVault
        );
    }
}

abstract contract XChainFinalize is Script, Deploy {
    ChainConfig dst;

    function _finalize() internal {

        Vault vault = srcDeployer.vaultProxy();
        uint256 amt = 999 * (10 ** vault.underlying().decimals());
        uint256 min = (amt * 99) / 100;

        XChainHubSingle srcHub = srcDeployer.hub(); 
        bytes memory dstHub = srcHub.trustedRemoteLookup(dst.id);
        address dstStrategy = srcHub.strategyForChain(dst.id);

        require(dstStrategy != address(0) && dstHub.length != 0, "Missing destination data");

        IHubPayload.Message memory message = IHubPayload.Message({
            action: srcDeployer.hub().FINALIZE_WITHDRAW_ACTION(),
            payload: abi.encode(
                IHubPayload.FinalizeWithdrawPayload({
                    vault: address(vault),
                    strategy: dstStrategy
                })
                )
        });

        (uint256 feeEstimate,) = srcRouter.quoteLayerZeroFee(
            dst.id,
            1, // function type
            abi.encodePacked(dstHub), // where to go
            abi.encode(message), // payload
            IStargateRouter.lzTxObj({
                dstGasForCall: 200_000,
                dstNativeAmount: 0,
                dstNativeAddr: abi.encodePacked(address(0x0))
            })
        );
        console.log("Fee Estimate", feeEstimate);

        srcHub.sg_finalizeWithdrawFromChain{value: feeEstimate}(
            IHubPayload.SgFinalizeParams({
                dstChainId: dst.id,
                vault: address(vault),
                strategy: dstStrategy,
                minOutUnderlying: min,
                srcPoolId: network.usdc.poolId,
                dstPoolId: dst.usdc.poolId,
                currentRound: vault.batchBurnRound(),
                refundAddress: payable(srcDeployer.refundAddress()),
                dstGas: dstDefaultGas
            })
        );
    }
}

/// @dev if redeploying hub on multiple chains you need to update remotes
/// @dev this assumes state variables are correct in the previous deploy
///      if, say you forgot to update state variables previously, this will fail
abstract contract RedeployXChainHub is Script, Setup {
    ChainConfig dstChain;

    function redeploy() internal {
        uint16 dstChainId = dstChain.id;

        require(dstChainId != 0, "SET DST CHAIN ID");

        XChainHubSingle oldHub = srcDeployer.hub();

        updateWithNewHub(srcDeployer, dstChainId);

        updateStrategyWithNewHub(srcDeployer);

        XChainHubSingle newHub = srcDeployer.hub();
        newHub.setVaultForChain(address(srcDeployer.vaultProxy()), dstChainId);

        transferVaultTokensToNewHub(srcDeployer, oldHub, newHub);

        // update the balances
        uint16[] memory chains = new uint16[](1);
        chains[0] = dstChainId;

        for (uint256 i; i < chains.length; i++) {
            uint16 chain = chains[i];
            address strat = newHub.strategyForChain(chain);
            uint256 shares = oldHub.sharesPerStrategy(chain, strat);
            require(shares != 0, "RedeployXChainHub::ZERO SHARES");
            newHub.setSharesPerStrategy(chain, strat, shares);
        }
    }
}


