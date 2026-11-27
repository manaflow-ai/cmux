import Foundation

/// The main-thread time of each resize step, by phase. A step is a window live resize's `ShellWindow.setFrame` (one per
/// mouse event, with cmux's own layout inside it) or a divider drag's frame tick (`LayoutRootView.advanceFrame`, which
/// writes the drag's newest pointer and lays the panes out); either one lasts until its run-loop turn has committed its
/// Core Animation transaction. Inside a step each part is its own entry: the root's `layout()` and its screens' fit, each
/// pane's layout by its content, the sidebar, the overlay sync, the Home transcript.
///
/// Two readers. DEBUG and bench builds keep the times (`debug.layout_counters` `resize_steps`; a divider step's phases
/// under `divider.`). Every build, Release too, writes them to the unified log while someone streams its debug messages
/// (``ResizeStepLog``). With nobody streaming a Release build times nothing and installs no observer: a live resize reads
/// one flag of the log per call (`Logger.isEnabled`).
@MainActor
public struct ResizeStepTimes {
    /// One phase's milliseconds per step, the last ``capacity`` steps.
    public private(set) var phases: [String: [Double]] = [:]
    public static let capacity = 2_048

    public init() {}

    /// The times of every window's resize steps (`debug.layout_counters` `resize_steps`).
    public static var live = ResizeStepTimes()

    /// What a step resizes.
    public enum StepKind: String, Sendable {
        /// A window live resize (its corner or an edge).
        case window
        /// A pane divider, column edge or row edge drag.
        case divider
    }

    /// Whether steps are timed: always in DEBUG and bench builds (which keep the times), in Release only while the log
    /// streams. Tests force it (``recordingOverride``) to check what a Release build with nobody streaming does.
    public static var isRecording: Bool {
        if let recordingOverride { return recordingOverride }
        #if DEBUG || CMUX_BENCH_HOOKS
        return true
        #else
        return ResizeStepLog.isStreaming
        #endif
    }

    /// Tests only: forces ``isRecording``.
    static var recordingOverride: Bool?

    /// Begins a step of `kind` when steps are timed and `condition` holds (built only then), and returns its start; else
    /// nil, and the caller measures nothing. `input` is the `NSEvent.timestamp` of the pointer event the step shows (a
    /// window step's current event); a divider step takes the events ``noteInput(_:)`` kept since the last one.
    public static func beginStep(_ kind: StepKind, if condition: @autoclosure () -> Bool = true,
                                 input: @autoclosure () -> Double? = nil) -> UInt64? {
        guard let hook = live.stepWillLayOut else {
            guard isRecording, condition() else { return nil }
            return ResizeStepLog.begin(kind, input: input())
        }
        // A hook runs at every step, timed or not, after the step opened (its time is the step's) and before the step's
        // layout. A step begun inside a pass is counted, never hooked again (``pass(_:_:)``).
        guard condition() else { return nil }
        if live.passDepth > 0 { live.nestedInPass += 1 }
        let start = isRecording ? ResizeStepLog.begin(kind, input: input()) : nil
        if live.passDepth == 0 { hook(kind) }
        return start
    }

    /// Runs at the start of every resize step, after it opened and before its layout (every build; nil: none). The CEF
    /// host runs the message pump work CEF already asked for here (`CEFMessagePump.runIfDueAtStep`, lever 4e).
    public var stepWillLayOut: (@MainActor (StepKind) -> Void)?

    /// Passes running now (``pass(_:_:)``), and the steps and timed phases that ran inside one: a pass's callbacks that
    /// reached cmux's views mid-step. Counted, logged, never hidden.
    var passDepth = 0
    public internal(set) var nestedInPass = 0

    /// Runs `body`, another component's work inside a step (a CEF message pump pass), as the phase `name`: the line
    /// says how long it took and how many steps and timed phases ran inside it (`nested=`). `body` returns the line's
    /// detail when it ran (` key=value` pairs), nil when it had nothing to do (no line).
    public static func pass(_ name: @autoclosure () -> String, _ body: () -> String?) {
        let start = DispatchTime.now().uptimeNanoseconds
        let nestedBefore = live.nestedInPass
        live.passDepth += 1
        let detail = body()
        live.passDepth -= 1
        guard let detail else { return }
        let nested = live.nestedInPass - nestedBefore
        recordLive(name(), since: isRecording ? start : nil, detail: detail + " nested=\(nested)")
    }

    /// Keeps a divider's pointer event (its `NSEvent.timestamp`) for the drag's next step, which reports how long the
    /// newest and the oldest one waited (`input_age`, `input_wait`).
    public static func noteInput(_ timestamp: Double) {
        guard isRecording else { return }
        ResizeStepLog.noteInput(timestamp)
    }

    /// ``start()`` inside a step, or in a live resize while steps are timed; else nil, and the caller measures nothing.
    public static func startIfLive(_ inLiveResize: Bool?) -> UInt64? {
        if ResizeStepLog.step != nil { return start() }
        return inLiveResize == true && isRecording ? start() : nil
    }

    /// ``start()`` while steps are timed (a divider's mouse event, outside any step), else nil.
    public static func startIfRecording() -> UInt64? {
        isRecording ? start() : nil
    }

    /// Records under `phase` (built only when there is a start) the time since `start`: into ``live`` in DEBUG and bench
    /// builds, and to the log while it streams. `kind` names a phase outside any step (a divider's mouse event); inside
    /// one, the step's kind.
    /// `detail` (built only while the log streams) follows the time on the phase's line, as ` key=value` pairs.
    public static func recordLive(_ phase: @autoclosure () -> String, kind: StepKind? = nil, since start: UInt64?,
                                  detail: @autoclosure () -> String = "") {
        guard let start else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        let kind = ResizeStepLog.step?.kind ?? kind ?? .window
        let name = phase()
        // A timed phase inside a pass (``pass(_:_:)``): cmux's layout ran from inside another component's work.
        let inPass = live.passDepth > 0
        if inPass { live.nestedInPass += 1 }
        keep(kind, name, ms)
        if ResizeStepLog.isStreaming, ResizeStepLog.keeps(name) {
            ResizeStepLog.write(kind, name, ms, detail: detail() + (inPass ? " in_pass=1" : ""))
        }
    }

    /// One fact of a step that is not a time of its own: a resize fence's wait and outcome (`CEFResizeFences`). `step`:
    /// the step it belongs to (a fence's page reports in a later turn); the open one by default.
    public static func note(_ phase: @autoclosure () -> String, ms: Double, step: UInt64? = nil, detail: @autoclosure () -> String = "") {
        guard ResizeStepLog.isStreaming else { return }
        let name = phase()
        guard ResizeStepLog.keeps(name) else { return }
        ResizeStepLog.write(ResizeStepLog.step?.kind ?? .window, name, ms, step: step, detail: detail())
    }

    /// The open step's number, while one is open and the log streams (for a fact reported later, ``note(_:ms:step:detail:)``).
    public static var openStep: UInt64? { ResizeStepLog.isStreaming ? ResizeStepLog.step?.id : nil }

    /// The time now, to pass to ``record(_:since:)`` after the phase's work. Two calls instead of one closure-taking
    /// `mutating` method: a phase measured inside another on the same value (the root's `layout()` inside
    /// `ShellWindow.setFrame`) then never holds the value across the inner one, which was a Swift exclusivity trap.
    public static func start() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Records the time since `start` under `phase` (DEBUG and bench builds; else nothing).
    public mutating func record(_ phase: String, since start: UInt64) {
        record(phase, ms: Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    mutating func record(_ phase: String, ms: Double) {
        #if DEBUG || CMUX_BENCH_HOOKS
        var list = phases[phase, default: []]
        if list.count >= Self.capacity { list.removeFirst(list.count - Self.capacity + 1) }
        list.append(ms)
        phases[phase] = list
        #endif
    }

    /// Into ``live`` (DEBUG and bench builds): a divider step's phases under `divider.`.
    static func keep(_ kind: StepKind, _ phase: String, _ ms: Double) {
        #if DEBUG || CMUX_BENCH_HOOKS
        live.record(kind == .window ? phase : "divider." + phase, ms: ms)
        #endif
    }

    /// Per phase: steps, p50, p95, max and the ten slowest steps' indexes and times.
    public func report() -> [String: [String: Any]] {
        phases.mapValues { values in
            let sorted = values.sorted()
            func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
            let slowest = values.enumerated().sorted { $0.element > $1.element }.prefix(10).map { [Double($0.offset), $0.element] }
            return ["steps": values.count, "p50_ms": pct(0.5), "p95_ms": pct(0.95), "max_ms": sorted.last ?? 0,
                    "total_ms": values.reduce(0, +), "slowest": slowest]
        }
    }

    public mutating func reset() { phases.removeAll(keepingCapacity: true) }
}
