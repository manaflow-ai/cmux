import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation

/// Supplies the shared RPC client with account-bound credentials and Tailscale-only networking.
public struct HiveSyncRuntime: MobileSyncRuntime {
    /// The unchanged shared Network.framework transport implementation.
    public let transportFactory: any CmxByteTransportFactory
    /// Returns a token only while the captured account session is still current.
    public let stackAccessTokenProvider: @Sendable () async throws -> String
    /// Returns a cached token scoped to the same authenticated session.
    public let stackAccessTokenForStatusProvider: @Sendable () async -> String?
    /// Refreshes a token without switching the captured account scope.
    public let stackAccessTokenForceRefresher: @Sendable () async throws -> String
    /// Tailscale, plus explicitly enabled debug loopback for isolated verification.
    public let supportedRouteKinds: [CmxAttachTransportKind]
    /// Upper bound for an individual RPC round trip.
    public let rpcRequestTimeoutNanoseconds: UInt64 = 30_000_000_000
    /// Upper bound for an individual pairing request or identity probe.
    public let pairingRequestTimeoutNanoseconds: UInt64 = 8_000_000_000
    /// Wall-clock source used by the shared client's ticket validation.
    public let now: @Sendable () -> Date = { Date() }
    /// The shared transport delivers host events without polling terminal output.
    public let supportsServerPushEvents = true

    /// Creates a transport adapter; callers must keep all token closures bound to one account generation.
    public init(
        allowsLoopback: Bool,
        accessToken: @escaping @Sendable () async throws -> String,
        cachedToken: @escaping @Sendable () async -> String?,
        refreshToken: @escaping @Sendable () async throws -> String
    ) {
        supportedRouteKinds = allowsLoopback ? [.tailscale, .debugLoopback] : [.tailscale]
        transportFactory = CmxNetworkByteTransportFactory(supportedKinds: supportedRouteKinds)
        stackAccessTokenProvider = accessToken
        stackAccessTokenForStatusProvider = cachedToken
        stackAccessTokenForceRefresher = refreshToken
    }
}
