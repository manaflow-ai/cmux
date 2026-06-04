public import CMUXMobileCore
public import Foundation

/// Runtime configuration the RPC layer needs, supplied by the app's DI bundle.
///
/// Keeping this as a protocol lets ``MobileCoreRPCClient`` depend only on
/// `CMUXMobileCore` while the app's `CMUXMobileRuntime` conforms to it at the
/// composition root. This avoids pulling the auth domain into the service layer.
public protocol MobileSyncRuntime: Sendable {
    /// Factory that builds a byte transport for a given attach route.
    var transportFactory: any CmxByteTransportFactory { get }
    /// Mints a Stack Auth access token for requests not covered by an attach ticket.
    var stackAccessTokenProvider: @Sendable () async throws -> String { get }
    /// Force-mints a fresh Stack Auth access token, bypassing any cached-token
    /// freshness check. The connection layer calls this exactly once after the
    /// host rejects a request on auth grounds, so the retry presents a genuinely
    /// new credential instead of re-sending the rejected (likely stale) token.
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String { get }
    /// Per-request timeout deadline, in nanoseconds.
    var rpcRequestTimeoutNanoseconds: UInt64 { get }
    /// Clock used to compare attach-ticket expiry, injected for testability.
    var now: @Sendable () -> Date { get }
    /// Transport kinds the app can dial, used to filter attach routes before
    /// connecting. Empty means "no filter" (accept every advertised route).
    var supportedRouteKinds: [CmxAttachTransportKind] { get }
    /// Shorter deadline for pairing-time requests (ticket mint, initial
    /// workspace list), in nanoseconds.
    var pairingRequestTimeoutNanoseconds: UInt64 { get }
    /// Whether the host supports server-pushed events. When `false`, the shell
    /// skips background subscribe/poll so scripted-transport tests do not
    /// consume responses intended for foreground methods.
    var supportsServerPushEvents: Bool { get }
}
