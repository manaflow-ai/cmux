import CmuxNextSignposts

/// Main-thread cost of terminal surface creation, for the stall bench
/// (`debug.timings`, scripts/cmux-next/bench-stalls.py), Instruments and the
/// trace ring: each `ghostty_surface_new` is one ``SignpostName/stallCreateSurface``
/// slice, and each phase of the runtime's one-time start one
/// ``SignpostName/stallGhosttyRuntimePhase`` event.
public struct TerminalTimings {
    /// The phases of the runtime's start (`GhosttyRuntime`), in their fixed ring order: the `arg0` of a
    /// ``SignpostName/stallGhosttyRuntimePhase`` record is the phase's position + 1 (0 for a name outside the list).
    enum RuntimePhase: String, CaseIterable {
        case ghosttyInit = "ghostty_init"
        case configLoad = "config_load"
        case appNew = "app_new"

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

    /// Begins and ends `ghostty_init`'s always-on launch interval (`launch.ghostty_init`, p08-startup-068).
    nonisolated static func ghosttyInitBegan() { LaunchSignposts().begin(.ghosttyInit) }
    nonisolated static func ghosttyInitEnded() { LaunchSignposts().end(.ghosttyInit) }

    /// Runs `ghostty_app_new` in `body` inside its always-on launch interval (`launch.ghostty_app_new`).
    static func ghosttyAppNew<Result>(_ body: () -> Result) -> Result { LaunchSignposts().measure(.ghosttyAppNew, body) }

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
    /// config load, `ghostty_app_new`), in order.
    public private(set) static var runtimePhases: [(name: String, duration: Duration)] = []

    static func runtimePhase(_ name: String, _ duration: Duration) {
        runtimePhases.append((name, duration))
        TerminalTimings().runtimePhaseEnded(name, duration)
    }
}
