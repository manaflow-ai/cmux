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
    /// Per-request timeout deadline, in nanoseconds.
    var rpcRequestTimeoutNanoseconds: UInt64 { get }
    /// Clock used to compare attach-ticket expiry, injected for testability.
    var now: @Sendable () -> Date { get }
}
