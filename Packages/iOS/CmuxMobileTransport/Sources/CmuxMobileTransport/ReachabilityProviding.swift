import Foundation

/// A network-reachability seam other layers depend on instead of a singleton.
///
/// Conformers report whether the system currently has a satisfied network path
/// and emit a value on every *meaningful* path change (regaining connectivity
/// after being offline, or the primary interface switching while online), so a
/// live connection can resync or reconnect when the network moves out from
/// under it.
///
/// The concrete ``ReachabilityService`` is constructed once at the app
/// composition root and injected as `any ReachabilityProviding`.
public protocol ReachabilityProviding: Sendable {
    /// Whether the system currently has a satisfied network path.
    var isOnline: Bool { get async }

    /// A stream that yields once per meaningful path change.
    ///
    /// Each element marks a change worth recovering from: connectivity returning
    /// after an offline window, or the primary interface type changing (for
    /// example Wi-Fi to cellular) while online. It deliberately does not emit on
    /// the first path delivery, so observers don't recover spuriously at startup.
    /// - Returns: An `AsyncStream` that completes when the provider is torn down.
    func pathChanges() -> AsyncStream<Void>
}
