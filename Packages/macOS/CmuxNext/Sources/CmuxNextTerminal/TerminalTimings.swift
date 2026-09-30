import os

/// Main-thread cost of terminal surface creation, for the stall bench
/// (`debug.timings`, scripts/cmux-next/bench-stalls.py) and Instruments
/// (signpost interval "createSurface", category "stalls").
public enum TerminalTimings {
    static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")

    /// Called on the main actor after each `ghostty_surface_new` with its
    /// duration (including the runtime's first-use start).
    public static var onSurfaceCreated: ((Duration) -> Void)?

    static func surfaceCreated(_ duration: Duration) {
        onSurfaceCreated?(duration)
    }

    /// Phases of the libghostty runtime's one-time start (`ghostty_init`,
    /// config load, `ghostty_app_new`), in order.
    public private(set) static var runtimePhases: [(name: String, duration: Duration)] = []

    static func runtimePhase(_ name: String, _ duration: Duration) {
        runtimePhases.append((name, duration))
        signposter.emitEvent("runtime", "\(name, privacy: .public)")
    }
}
