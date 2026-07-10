import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
@testable import CmuxMobileRPC

extension MobileCoreRPCClient {
    static func testClient(
        runtime: any MobileSyncRuntime,
        route: CmxAttachRoute,
        ticket: CmxAttachTicket,
        allowsStackAuthFallback: Bool = false,
        manualHostStackAuthTrustProvider: @escaping @Sendable () async -> Bool = { false },
        authScope: MobileRPCAuthScope = MobileRPCAuthScope(),
        authScopeValidator: @escaping @Sendable () async -> Bool = { true },
        connectAttemptRegistry: MobileRPCConnectAttemptRegistry = MobileRPCConnectAttemptRegistry(),
        stackTokenGate: RPCStackTokenGate? = nil,
        stackTokenForceRefreshGate: RPCStackTokenGate? = nil,
        abandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000,
        lateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000,
        stackTokenGateResetNanoseconds: UInt64 = 30_000_000_000
    ) -> MobileCoreRPCClient {
        MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: allowsStackAuthFallback,
            manualHostStackAuthTrustProvider: manualHostStackAuthTrustProvider,
            authScope: authScope,
            authScopeValidator: authScopeValidator,
            connectAttemptRegistry: connectAttemptRegistry,
            stackTokenGate: stackTokenGate,
            stackTokenForceRefreshGate: stackTokenForceRefreshGate,
            abandonedConnectCleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateAbandonedConnectCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds,
            stackTokenGateResetNanoseconds: stackTokenGateResetNanoseconds
        )
    }
}
