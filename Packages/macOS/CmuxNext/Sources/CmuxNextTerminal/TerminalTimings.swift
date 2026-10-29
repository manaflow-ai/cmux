import CmuxNextSignposts

/// Main-thread cost of terminal surface creation, for the stall bench
/// (`debug.timings`, scripts/cmux-next/bench-stalls.py), Instruments and the
/// trace ring: each `ghostty_surface_new` is one ``SignpostName/stallCreateSurface``
/// slice, and each phase of the runtime's one-time start one
/// ``SignpostName/stallGhosttyRuntimePhase`` event.
public struct TerminalTimings {
    /// The phases of the runtime's start (`GhosttyRuntime`) and of its first surface (``TerminalFirstSurfaceSplit``),
    /// in their fixed ring order: the `arg0` of a ``SignpostName/stallGhosttyRuntimePhase`` record is the phase's
    /// position + 1 (0 for a name outside the list). New phases go at the end, so a code never changes meaning.
    enum RuntimePhase: String, CaseIterable {
        case ghosttyInit = "ghostty_init"
        case configLoad = "config_load"
        case appNew = "app_new"
        /// The first `ghostty_surface_new`: the font grid (discovery and the face loads), the renderer, its thread.
        case surfaceNew = "surface_new"
        /// The view's own setup of that surface: host sizing, the font scale hook, the color scheme, the output lane.
        case surfaceSetup = "surface_setup"
        /// Its first content scale and size: a scale unlike the surface config's builds a second font grid.
        case surfaceFit = "surface_fit"
        /// Its first occlusion and focus.
        case surfaceState = "surface_state"

        /// The ring code of the phase `name`.
        static func traceCode(of name: String) -> UInt64 {
            allCases.firstIndex { $0.rawValue == name }.map { UInt64(clamping: $0) + 1 } ?? 0
        }
    }

    /// Where surface creates and the runtime's phases go (a `stall` signposter).
    private let stall: Signposter
    /// Takes each surface create's duration.
    private let report: (Duration) -> Void

    /// The app's timings: the `stall` signposter, reporting to ``onSurfaceCreated``.
    public init() {
        self.init(stall: .stall)
    }

    /// - Parameters:
    ///   - stall: Where surface creates and the runtime's phases go (a `stall` signposter).
    ///   - report: Takes each surface create's duration (by default ``onSurfaceCreated``).
    init(stall: Signposter, report: @escaping (Duration) -> Void = { TerminalTimings.onSurfaceCreated?($0) }) {
        self.stall = stall
        self.report = report
    }

    /// Called on the main actor after each `ghostty_surface_new` with its
    /// duration (including the runtime's first-use start).
    public static var onSurfaceCreated: ((Duration) -> Void)?

    /// Begins the `stall.create_surface` slice of one `ghostty_surface_new`.
    func surfaceCreateBegan() -> SignpostInterval {
        stall.begin(.stallCreateSurface)
    }

    /// Ends the slice ``surfaceCreateBegan()`` began and reports its
    /// duration, measured on the slice's own clock.
    func surfaceCreated(_ interval: SignpostInterval) {
        let elapsed = stall.nowNanos() &- interval.beginUptimeNanos
        stall.end(.stallCreateSurface, interval)
        report(.nanoseconds(Int64(clamping: elapsed)))
    }

    /// Begins and ends `ghostty_init`'s always-on launch interval (`launch.ghostty_init`).
    nonisolated static func ghosttyInitBegan() { LaunchSignposts().begin(.ghosttyInit) }
    nonisolated static func ghosttyInitEnded() { LaunchSignposts().end(.ghosttyInit) }

    /// Runs `ghostty_app_new` in `body` inside its always-on launch interval (`launch.ghostty_app_new`).
    static func ghosttyAppNew<Result>(_ body: () -> Result) -> Result { LaunchSignposts().measure(.ghosttyAppNew, body) }

    /// Begins and ends the first `ghostty_surface_new`'s always-on launch interval (`launch.first_surface_new`).
    static func firstSurfaceNewBegan() { LaunchSignposts().begin(.firstSurfaceNew) }
    static func firstSurfaceNewEnded() { LaunchSignposts().end(.firstSurfaceNew) }

    /// Records the runtime's start phase `name`, which just ended after `duration`.
    func runtimePhaseEnded(_ name: String, _ duration: Duration) {
        let nanos = UInt64(clamping: duration.components.seconds) &* 1_000_000_000
            &+ UInt64(clamping: duration.components.attoseconds / 1_000_000_000)
        stall.event(.stallGhosttyRuntimePhase, "phase=\(name)", arg0: RuntimePhase.traceCode(of: name), arg1: nanos)
    }

    /// Called on the main actor each time a surface was handed terminal
    /// content (a replay or output) from its IO, for the launch's
    /// "first live terminal frame" mark and `launch.visible_terminals_drawn`, which waits for that session's frame.
    public static var onContentApplied: ((TerminalSession) -> Void)?

    static func contentApplied(_ session: TerminalSession) {
        onContentApplied?(session)
    }

    /// Phases of the libghostty runtime's one-time start (`ghostty_init`,
    /// config load, `ghostty_app_new`) and of its first surface, in order.
    public private(set) static var runtimePhases: [(name: String, duration: Duration)] = []

    static func runtimePhase(_ name: String, _ duration: Duration) {
        runtimePhases.append((name, duration))
        TerminalTimings().runtimePhaseEnded(name, duration)
    }
}

/// Splits the cost of a runtime's first terminal surface into ``TerminalTimings/RuntimePhase`` phases: the
/// `ghostty_surface_new` call itself (`launch.first_surface_new`), then the view's setup, first fit and first state.
/// Each phase goes where the runtime's start phases go (`debug.timings`' `ghostty_runtime_ms`, a
/// `stall.ghostty_runtime_phase` event). Only the first surface pays the font discovery and the Metal device's first
/// use, so later surfaces are not split. One per runtime (``GhosttyRuntime/firstSurfaceSplit``).
///
/// ```swift
/// var split = runtime.firstSurfaceSplit.begin() // nil for every surface after the first
/// let surface = ghostty_surface_new(app, &config)
/// split?.ended(.surfaceNew)
/// ```
final class TerminalFirstSurfaceSplit {
    /// The running split of the first surface: each ``ended(_:)`` closes the phase since the one before.
    struct Run {
        fileprivate let split: TerminalFirstSurfaceSplit
        private var phaseStart: ContinuousClock.Instant

        fileprivate init(split: TerminalFirstSurfaceSplit) {
            self.split = split
            phaseStart = split.now()
        }

        /// Records `phase`, which ends now. `.surfaceNew` also ends `launch.first_surface_new`.
        mutating func ended(_ phase: TerminalTimings.RuntimePhase) {
            let end = split.now()
            if phase == .surfaceNew { split.surfaceNewEnded() }
            split.record(phase.rawValue, phaseStart.duration(to: end))
            phaseStart = end
        }
    }

    private var taken = false
    fileprivate let now: () -> ContinuousClock.Instant
    fileprivate let record: (String, Duration) -> Void
    private let surfaceNewBegan: () -> Void
    fileprivate let surfaceNewEnded: () -> Void

    /// The app's split: phases to ``TerminalTimings/runtimePhase(_:_:)``, the always-on launch signpost around
    /// `ghostty_surface_new`.
    convenience init() {
        self.init(now: { .now }, record: { TerminalTimings.runtimePhase($0, $1) },
                  surfaceNewBegan: { TerminalTimings.firstSurfaceNewBegan() },
                  surfaceNewEnded: { TerminalTimings.firstSurfaceNewEnded() })
    }

    /// - Parameters:
    ///   - now: The clock the phases are measured on.
    ///   - record: Takes each phase's name and duration.
    ///   - surfaceNewBegan: Runs when the first `ghostty_surface_new` begins.
    ///   - surfaceNewEnded: Runs when it ends (``Run/ended(_:)`` with `.surfaceNew`).
    init(now: @escaping () -> ContinuousClock.Instant, record: @escaping (String, Duration) -> Void,
         surfaceNewBegan: @escaping () -> Void = {}, surfaceNewEnded: @escaping () -> Void = {}) {
        self.now = now
        self.record = record
        self.surfaceNewBegan = surfaceNewBegan
        self.surfaceNewEnded = surfaceNewEnded
    }

    /// The split of the surface about to be made, right before its `ghostty_surface_new`; nil after the first call.
    func begin() -> Run? {
        guard !taken else { return nil }
        taken = true
        surfaceNewBegan()
        return Run(split: self)
    }
}
