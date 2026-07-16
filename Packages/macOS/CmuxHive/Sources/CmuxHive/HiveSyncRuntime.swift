public import CMUXMobileCore
public import CmuxMobileRPC
import CmuxMobileTransport
public import Foundation

/// macOS conformance of the RPC layer's `MobileSyncRuntime`, mirroring the
/// iOS app's `CMUXMobileRuntime`: a Network.framework TCP transport factory
/// over the supported route kinds plus injected Stack-token closures.
///
/// Constructed once at the app's composition root and shared by every
/// remote-Mac session.
public struct HiveSyncRuntime: MobileSyncRuntime, Sendable {
    /// Default per-request RPC deadline (matches the iOS runtime).
    public static let defaultRPCRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000

    public var supportedRouteKinds: [CmxAttachTransportKind]
    public var transportFactory: any CmxByteTransportFactory
    public var stackAccessTokenProvider: @Sendable () async throws -> String
    public var stackAccessTokenForStatusProvider: @Sendable () async -> String?
    public var stackAccessTokenForceRefresher: @Sendable () async throws -> String
    public var rpcRequestTimeoutNanoseconds: UInt64
    public var pairingRequestTimeoutNanoseconds: UInt64
    public var now: @Sendable () -> Date
    public var supportsServerPushEvents: Bool

    /// Creates a runtime over an explicit transport factory (tests inject a
    /// scripted one).
    public init(
        supportedRouteKinds: [CmxAttachTransportKind],
        transportFactory: any CmxByteTransportFactory,
        stackAccessTokenProvider: @escaping @Sendable () async throws -> String,
        stackAccessTokenForStatusProvider: @escaping @Sendable () async -> String? = { nil },
        stackAccessTokenForceRefresher: @escaping @Sendable () async throws -> String,
        rpcRequestTimeoutNanoseconds: UInt64 = Self.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = 8 * 1_000_000_000,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider
        self.stackAccessTokenForStatusProvider = stackAccessTokenForStatusProvider
        self.stackAccessTokenForceRefresher = stackAccessTokenForceRefresher
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.now = now
        self.supportsServerPushEvents = supportsServerPushEvents
    }

    /// Builds the production runtime over the Network.framework TCP transport,
    /// composed exactly like the iOS app's root: one network factory
    /// registered per supported route kind.
    ///
    /// - Parameters:
    ///   - allowsLoopbackRoutes: Include `.debugLoopback` (dev builds pairing
    ///     two instances on one machine).
    ///   - stackAccessTokenProvider: Mints the Stack access token.
    ///   - stackAccessTokenForceRefresher: Force-mints a fresh token after an
    ///     auth rejection.
    public static func network(
        allowsLoopbackRoutes: Bool,
        stackAccessTokenProvider: @escaping @Sendable () async throws -> String,
        stackAccessTokenForceRefresher: @escaping @Sendable () async throws -> String
    ) -> HiveSyncRuntime {
        let supportedKinds: [CmxAttachTransportKind] = allowsLoopbackRoutes
            ? [.debugLoopback, .tailscale]
            : [.tailscale]
        // Tailscale goes through the viewer's own tailnet-verified factory:
        // the shared network factory fails closed for tailscale (correct for
        // phone pairings from untrusted payloads), while the viewer's routes
        // come from the account's own device registry.
        let networkFactory = CmxNetworkByteTransportFactory(supportedKinds: supportedKinds)
        let registrations = supportedKinds.map { kind in
            CmxRouteTransportFactoryRegistration(
                kind: kind,
                factory: kind == .tailscale
                    ? HiveTailscaleByteTransportFactory()
                    : networkFactory
            )
        }
        let transportFactory: any CmxByteTransportFactory
        do {
            transportFactory = try CmxRouteTransportFactory(registrations)
        } catch {
            // Unreachable: the registrations are one per distinct kind.
            transportFactory = networkFactory
        }
        return HiveSyncRuntime(
            supportedRouteKinds: supportedKinds,
            transportFactory: transportFactory,
            stackAccessTokenProvider: stackAccessTokenProvider,
            stackAccessTokenForceRefresher: stackAccessTokenForceRefresher
        )
    }
}
