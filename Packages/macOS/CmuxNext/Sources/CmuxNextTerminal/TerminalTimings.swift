import CmuxNextSignposts

/// Main-thread cost of terminal surface creation, for the stall bench
/// (`debug.timings`, scripts/cmux-next/bench-stalls.py), Instruments and the
/// trace ring (``SignpostName/stallCreateSurface``; the runtime's start phases
/// are `launch.ghostty_runtime` events).
public struct TerminalTimings {
    public init() {}
    static let stall = Signposter.stall
    static let launch = Signposter.launch

    /// Called on the main actor after each `ghostty_surface_new` with its
    /// duration (including the runtime's first-use start).
    public static var onSurfaceCreated: ((Duration) -> Void)?

    /// Begins the `stall.create_surface` interval of one `ghostty_surface_new`.
    static func surfaceCreateBegan() -> SignpostInterval {
        stall.begin(.stallCreateSurface)
    }

    /// Ends the interval ``surfaceCreateBegan()`` began and reports its
    /// duration, measured on the interval's own clock.
    static func surfaceCreated(_ interval: SignpostInterval) {
        let elapsed = stall.nowNanos() &- interval.beginUptimeNanos
        stall.end(.stallCreateSurface, interval)
        onSurfaceCreated?(.nanoseconds(Int64(clamping: elapsed)))
    }

    /// Called on the main actor each time a surface was handed terminal
    /// content (a replay or output) from its IO, for the launch's
    /// "first live terminal frame" mark.
    public static var onContentApplied: (() -> Void)?

    static func contentApplied() {
        onContentApplied?()
    }

    /// Phases of the libghostty runtime's one-time start (`ghostty_init`,
    /// config load, `ghostty_app_new`), in order.
    public private(set) static var runtimePhases: [(name: String, duration: Duration)] = []

    static func runtimePhase(_ name: String, _ duration: Duration) {
        runtimePhases.append((name, duration))
        launch.launchStep(.ghosttyRuntime, name)
    }
}
