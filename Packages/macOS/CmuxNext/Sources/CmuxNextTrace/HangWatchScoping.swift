/// The part of ``HangWatch`` a watched lane calls: register once, run each unit of work in a scope,
/// unregister when the lane ends. ``HangWatch`` is the one implementation (the app passes
/// `TraceRuntime.shared.hangWatch` from its composition root); the protocol exists so a lane's owner
/// takes it by `init` and a test passes a recording fake. It adds no hang-watch state of its own.
///
/// The scope is the body form of ``HangWatch/watch(_:deadline:_:)``, so it closes exactly once, on the
/// thread that opened it, as Chrome's `WatchHangsInScope` (base/threading/hang_watcher.h).
public protocol HangWatchScoping: Sendable {
    /// Registers a lane whose units of work may run on any thread (``HangWatch/registerLane(_:)``).
    func registerLane(_ name: StaticString) -> HangWatch.Registration
    /// Frees the lane's slot (``HangWatch/unregister(_:)``).
    func unregister(_ registration: HangWatch.Registration)
    /// Runs `body` inside one scope on `registration`'s slot (``HangWatch/watch(_:deadline:_:)``).
    func watch<T>(_ registration: HangWatch.Registration, deadline: Duration, _ body: () throws -> T) rethrows -> T
}

extension HangWatch: HangWatchScoping {}

/// One registered lane and the deadline of each of its units of work: what a lane owner keeps, so each
/// unit is one ``run(_:)``. Wrap only work the lane does itself, never a `read(2)` that waits for input
/// or a wait for a queue slot: those are idle time, not a hang.
///
/// ```swift
/// let watched = HangWatchedLane("daemon.line", deadline: .milliseconds(100), on: hangWatch)
/// watched.run { route(line) }
/// ```
public struct HangWatchedLane: Sendable {
    private let watch: any HangWatchScoping
    private let registration: HangWatch.Registration
    /// How long one unit of work may run before it is reported as a hang.
    public let deadline: Duration

    /// Registers lane `name` on `watch`.
    public init(_ name: StaticString, deadline: Duration, on watch: any HangWatchScoping) {
        self.watch = watch
        self.deadline = deadline
        registration = watch.registerLane(name)
    }

    /// Runs one unit of work inside the lane's scope.
    public func run<T>(_ body: () throws -> T) rethrows -> T {
        try watch.watch(registration, deadline: deadline, body)
    }

    /// Frees the lane's slot; call once, when the lane ends.
    public func unregister() {
        watch.unregister(registration)
    }
}
