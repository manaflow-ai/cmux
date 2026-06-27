import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation

struct DurableTicketFallbackRuntime: MobileSyncRuntime {
    var transportFactory: any CmxByteTransportFactory
    var stackAccessTokenProvider: @Sendable () async throws -> String = { "fresh-stack-token" }
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "fresh-stack-token" }
    var rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var now: @Sendable () -> Date
    var supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale]
    var pairingRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var supportsServerPushEvents: Bool = false
}
