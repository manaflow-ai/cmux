import os

/// Main-thread cost of terminal surface creation, for the stall bench
/// (`debug.timings`, scripts/cmux-next/bench-stalls.py) and Instruments
/// (signpost interval "createSurface", category "stalls").
public struct TerminalTimings {
    public init() {}
    static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "stalls")

    /// Called on the main actor after each `ghostty_surface_new` with its
    /// duration (including the runtime's first-use start).
    public static var onSurfaceCreated: ((Duration) -> Void)?

    static func surfaceCreated(_ duration: Duration) {
        onSurfaceCreated?(duration)
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
        signposter.emitEvent("runtime", "\(name, privacy: .public)")
    }
}
