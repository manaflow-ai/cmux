#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Foundation

/// Times the main run loop's non-Swift callouts that held up a person's input, for
/// ``InputTurnHopRecorder`` (task 022): the stretch after a wake (a timer, the main dispatch
/// queue or a mach-port source, then the run loop's blocks) and the source and block pass (with the
/// main-queue drain CFRunLoop's poll can add to it), each from the last observer of the stage that
/// starts it to the first observer of the stage that ends it, so no other observer's time counts.
/// Every stretch is timed; it is recorded when input was pending at its start or at its end: a
/// callout that was already running when a key arrived delays that key too, as Chrome attributes
/// input queueing time to the tasks that ran ahead of the input
/// (`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`).
/// A stretch shorter than ``minimumNanos`` (an empty pass) is not recorded. With a
/// ``CalloutStackSampler``, a long stretch that starts in or within ``hotWindowNanos`` of an input
/// turn is sampled and counts under the callout's own site.
///
/// The main dispatch queue's drain also runs Swift main-actor jobs: their own sites are the
/// recorder's swift rows, and the rows that can hold them say ``InputTurnHopRecorder/Row/includesSwiftJobs``.
/// A nested run loop inside a callout (menu tracking, a modal session) ends the outer stretch's
/// timing: its own stretches are timed at its depth.
///
/// Its stages that end a stretch wake the recorder's fold when records wait, the passes that never
/// wait (a busy main thread) included.
///
/// ```swift
/// let timer = InputTurnCalloutTimer(diagnostics: hops, sampler: sampler) { InputTurn(pending: kinds(), dispatching: false) }
/// ```
@MainActor
public final class InputTurnCalloutTimer {
    /// Callouts shorter than this are not recorded (an empty source pass takes about a microsecond).
    public static let minimumNanos: UInt64 = 20_000
    /// How long after an input turn a stretch that starts is sampled.
    public static let hotWindowNanos: UInt64 = 100_000_000

    private let diagnostics: InputTurnHopRecorder
    private let sampler: CalloutStackSampler?
    private let turn: @MainActor () -> InputTurnHopRecorder.InputTurn
    private let now: @MainActor () -> UInt64
    private let timerDue: @MainActor () -> Bool
    private let mode: @MainActor () -> InputTurnHopRecorder.RunLoopModeName
    private var depth = 0
    private var open: Open?
    private var generation: UInt64 = 0
    /// When the last turn with input was seen; 0 before the first.
    private var lastInputNanos: UInt64 = 0
    private var observers: [MainRunLoopObserver] = []

    /// A stretch being timed.
    private struct Open {
        var callout: InputTurnHopRecorder.CalloutKind
        var mode: InputTurnHopRecorder.RunLoopModeName
        /// The input pending at the start.
        var turn: InputTurnHopRecorder.InputTurn
        var depth: Int
        var startNanos: UInt64
        /// The sampler's generation; 0 when it was not armed.
        var generation: UInt64
    }

    /// - Parameters:
    ///   - diagnostics: The recorder.
    ///   - sampler: Names long callouts' sites (nil: every callout counts under its stretch).
    ///   - observing: False adds no run-loop observer (tests drive ``observe(_:)``).
    ///   - now: Uptime in nanoseconds.
    ///   - timerDue: Whether a main run-loop timer is due now (after a wake: the wake is a timer's).
    ///   - mode: The main run loop's mode now.
    ///   - turn: The input of the turn now (the pending-input state, task 021): empty means no input.
    public init(diagnostics: InputTurnHopRecorder, sampler: CalloutStackSampler? = nil, observing: Bool = true,
                now: @escaping @MainActor () -> UInt64 = { MainTaskPost.uptimeNanos() },
                timerDue: @escaping @MainActor () -> Bool = InputTurnCalloutTimer.mainTimerDue,
                mode: @escaping @MainActor () -> InputTurnHopRecorder.RunLoopModeName = InputTurnCalloutTimer.mainMode,
                turn: @escaping @MainActor () -> InputTurnHopRecorder.InputTurn) {
        self.diagnostics = diagnostics
        self.sampler = sampler
        self.turn = turn
        self.now = now
        self.timerDue = timerDue
        self.mode = mode
        guard observing else { return }
        // First at the stages that end a stretch, last at the stages that start one.
        observers = [
            MainRunLoopObserver(activities: [.entry, .beforeTimers, .beforeWaiting, .exit], order: .min) { [weak self] activity in
                self?.observe(activity)
            },
            MainRunLoopObserver(activities: [.afterWaiting, .beforeSources], order: MainRunLoopObserver.lastOrder) { [weak self] activity in
                self?.observe(activity)
            },
        ]
    }

    /// Stops observing (also on release).
    public func invalidate() {
        observers.forEach { $0.invalidate() }
        observers = []
    }

    /// One run-loop stage (the observers, or a test).
    func observe(_ activity: CFRunLoopActivity) {
        switch activity {
        case .entry:
            depth += 1
        case .afterWaiting:
            start(timerDue() ? .timer : .mainQueueOrPort)
        case .beforeSources:
            start(.sources)
        case .beforeTimers, .beforeWaiting:
            // A pass reached by CFRunLoop's poll skips beforeWaiting: every end wakes the fold.
            end()
            diagnostics.wakeFold()
        case .exit:
            end()
            diagnostics.wakeFold()
            depth = max(0, depth - 1)
        default:
            break
        }
    }

    private func start(_ callout: InputTurnHopRecorder.CalloutKind) {
        let input = turn()
        let startNanos = now()
        if !input.isEmpty { lastInputNanos = startNanos }
        var armed: UInt64 = 0
        if let sampler, lastInputNanos != 0, startNanos &- lastInputNanos <= Self.hotWindowNanos {
            generation += 1
            armed = generation
            sampler.arm(armed)
        }
        open = Open(callout: callout, mode: mode(), turn: input, depth: depth, startNanos: startNanos, generation: armed)
    }

    private func end() {
        guard let started = open else { return }
        open = nil
        if started.generation != 0 { sampler?.disarm() }
        // A nested run loop ran inside the callout: its own stages were timed at its depth.
        guard started.depth == depth else { return }
        let endNanos = now()
        let input = started.turn.union(turn())
        guard !input.isEmpty else { return }
        lastInputNanos = endNanos
        let nanos = endNanos &- started.startNanos
        guard nanos >= Self.minimumNanos else { return }
        var record = HopRecord(lane: .nonswift, origin: started.mode.rawValue, turn: input, callout: started.callout, nanos: nanos)
        if started.generation != 0 { sampler?.fill(&record, generation: started.generation) }
        diagnostics.push(record)
    }

    /// Whether a timer of the main run loop's current mode is due now.
    public nonisolated static func mainTimerDue() -> Bool {
        let main = CFRunLoopGetMain()
        guard let current = CFRunLoopCopyCurrentMode(main) else { return false }
        // 0: the mode has no timer.
        let next = CFRunLoopGetNextTimerFireDate(main, current)
        return next > 0 && next <= CFAbsoluteTimeGetCurrent()
    }

    /// The main run loop's current mode.
    public nonisolated static func mainMode() -> InputTurnHopRecorder.RunLoopModeName {
        guard let current = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) else { return .other }
        let name = current.rawValue as String
        if name == CFRunLoopMode.defaultMode.rawValue as String { return .default }
        switch name {
        case "NSEventTrackingRunLoopMode": return .eventTracking
        case "NSModalPanelRunLoopMode": return .modalPanel
        default: return .other
        }
    }
}
#endif
