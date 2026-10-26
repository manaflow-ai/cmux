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

    static let firstSurfacePrefix = "first_surface."

    /// The first surface's phases land in ``runtimePhases``, once per process.
    static func surfaceCreated(_ duration: Duration, phases: SurfaceCreationPhases) {
        if !runtimePhases.contains(where: { $0.name.hasPrefix(firstSurfacePrefix) }) {
            for phase in phases.phases { runtimePhases.append((firstSurfacePrefix + phase.name, phase.duration)) }
        }
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
    /// config load, `ghostty_app_new`), in order, then the first surface's
    /// creation split into its phases (`first_surface.<phase>`, see
    /// ``SurfaceCreationPhases``). `debug.timings` reports them as
    /// `ghostty_runtime_ms`.
    public private(set) static var runtimePhases: [(name: String, duration: Duration)] = []

    static func runtimePhase(_ name: String, _ duration: Duration) {
        runtimePhases.append((name, duration))
        signposter.emitEvent("runtime", "\(name, privacy: .public)")
    }
}

/// One surface creation split into its phases, each ending at a `mark`:
/// `runtime` (the shared runtime, its one-time start for the first surface),
/// `config` (the surface config: the screen's scale), `surface_new`
/// (`ghostty_surface_new`: font grid, renderer and its Metal pipelines, IO
/// and renderer threads) and `attach` (size, scale, occlusion, focus).
/// Each mark is also a "surfacePhase" signpost event inside the
/// "createSurface" interval, so Instruments shows the split for every surface.
struct SurfaceCreationPhases {
    private(set) var phases: [(name: String, duration: Duration)] = []
    private var phaseStart: ContinuousClock.Instant

    init(start: ContinuousClock.Instant) {
        phaseStart = start
    }

    mutating func mark(_ name: String, at now: ContinuousClock.Instant = .now) {
        phases.append((name, phaseStart.duration(to: now)))
        phaseStart = now
        TerminalTimings.signposter.emitEvent("surfacePhase", "\(name, privacy: .public)")
    }
}
