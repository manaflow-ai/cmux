import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation
@testable import CmuxMobileShell

struct PairingDeadlineRuntime: MobileSyncRuntime {
    var transportFactory: any CmxByteTransportFactory = SlowIgnoringCancellationTransportFactory()
    var stackAccessTokenProvider: @Sendable () async throws -> String = { "test-stack-token" }
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-stack-token" }
    var rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var now: @Sendable () -> Date = { Date() }
    var supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale]
    var pairingRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var pairingAttemptTimeoutNanoseconds: UInt64 = 1_000_000
    var supportsServerPushEvents: Bool = false
}
