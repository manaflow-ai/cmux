import Foundation

/// Starts the app's own browser hosts for phones (hostd's `browser` service,
/// cnx-ios/verify/browser-stream.md): the same `cmux-remote-browser-host`
/// this build runs for its remote browser tabs, one per phone tab, on loopback.
public protocol CnxBrowserHosting: Sendable {
    /// Starts a host for `tab` on `url` and returns where it listens and its
    /// per-launch secret. `onExit` runs once when that host exits.
    func start(tab: String, url: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String)
    /// Stops the host of `tab` (hostd evicted it or no longer needs it).
    func stop(tab: String) async
    /// Stops every host (hostd restarted or stopped).
    func stopAll() async
}
