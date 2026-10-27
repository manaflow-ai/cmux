import Foundation

/// Starts the app's own browser hosts for phones (hostd's `browser` service,
/// cmux-next-ios/verify/browser-stream.md): the same `cmux-remote-browser-host`
/// this build runs for its remote browser tabs, one per phone tab, on loopback.
public protocol MobileHostBrowserHosting: Sendable {
    /// Starts a host for `tab` on `url` and returns where it listens and its
    /// per-launch secret. `onExit` runs once when that host exits.
    func start(tab: String, url: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String)
    /// Stops the host of `tab` (hostd evicted it or no longer needs it).
    func stop(tab: String) async
    /// Stops every host (hostd restarted or stopped).
    func stopAll() async
}

/// Starts frame sources for the simulators the phone streams (hostd's `surface`
/// service, cmux-next-ios/verify/simulator-surface.md): one per phone tab of this
/// Mac, on loopback, each speaking `sf/1` with its own secret.
public protocol MobileHostSurfaceHosting: Sendable {
    /// Starts the source of phone tab `tab` (`s<surface>`) and returns where it
    /// listens and its per-launch secret. Throws when `tab` is not a phone tab of
    /// this Mac showing a booted simulator. `onExit` runs once when it ends.
    func start(tab: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String)
    /// Stops the source of `tab`.
    func stop(tab: String) async
    /// Stops every source (hostd restarted or stopped).
    func stopAll() async
}

/// ``MobileHostSurfaceHosting`` from three closures, so the app can hand hostd its simulator
/// sources (CmuxNextPhone) without this package depending on them.
public struct MobileHostSurfaceClosures: MobileHostSurfaceHosting {
    private let startSource: @Sendable (String, @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String)
    private let stopSource: @Sendable (String) async -> Void
    private let stopSources: @Sendable () async -> Void

    public init(start: @escaping @Sendable (String, @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String),
                stop: @escaping @Sendable (String) async -> Void, stopAll: @escaping @Sendable () async -> Void) {
        startSource = start
        stopSource = stop
        stopSources = stopAll
    }

    public func start(tab: String, onExit: @escaping @Sendable () -> Void) async throws -> (port: UInt16, secret: String) {
        try await startSource(tab, onExit)
    }

    public func stop(tab: String) async { await stopSource(tab) }
    public func stopAll() async { await stopSources() }
}
