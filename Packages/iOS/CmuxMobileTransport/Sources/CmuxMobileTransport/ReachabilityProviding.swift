import Foundation

/// A network-reachability seam other layers depend on instead of a singleton.
///
/// Conformers report whether the system currently has a satisfied network path
/// and emit a value on every path update after the initial snapshot, so a live
/// connection can resync or reconnect when the network moves out from under it.
/// This deliberately includes updates that keep the same primary interface
/// type: Wi-Fi roaming can move to a different LAN without a `.wifi`→cellular
/// transition.
///
/// The concrete ``ReachabilityService`` is constructed once at the app
/// composition root and injected as `any ReachabilityProviding`.
public protocol ReachabilityProviding: Sendable {
    /// Whether the system currently has a satisfied network path.
    var isOnline: Bool { get async }

    /// A stream that yields once per path update after the initial snapshot.
    ///
    /// Same-interface updates are included so Wi-Fi→Wi-Fi roaming invalidates
    /// network-scoped trust. The first path delivery is omitted so observers do
    /// not recover spuriously at startup.
    /// - Returns: An `AsyncStream` that completes when the provider is torn down.
    func pathChanges() -> AsyncStream<Void>
}
