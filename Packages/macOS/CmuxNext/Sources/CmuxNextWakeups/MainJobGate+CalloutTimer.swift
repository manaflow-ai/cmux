#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Foundation
import Darwin

/// Times the main run loop's non-Swift callouts that start during an input turn, for
/// ``MainJobGateDiagnostics`` (task 022): the stretch after a wake (a timer, the main dispatch
/// queue or a mach-port source, then the run loop's blocks) and the source and block pass, each from
/// the last observer of the stage that starts it to the first observer of the stage that ends it,
/// so no other observer's time counts. A callout shorter than ``minimumNanos`` (an empty pass) is
/// not recorded.
///
/// The main dispatch queue's drain also runs Swift main-actor jobs: their own sites are the
/// recorder's swift rows, enqueued by the MainJobGate hook. A nested run loop inside a callout
/// (menu tracking, a modal session) ends the outer stretch's timing: its own callouts are timed at
/// its depth.
///
/// Its run-loop pass also wakes the recorder's fold once per turn that left records.
///
/// ```swift
/// let timer = InputTurnCalloutTimer(diagnostics: hops) { InputTurn(pending: state.pending, dispatching: state.dispatching) }
/// ```
@MainActor
public final class InputTurnCalloutTimer {
    /// Callouts shorter than this are not recorded (an empty source pass takes about a microsecond).
    public static let minimumNanos: UInt64 = 20_000

    private let diagnostics: MainJobGateDiagnostics
    private let turn: @MainActor () -> MainJobGateDiagnostics.InputTurn
    private let now: @MainActor () -> UInt64
    private let timerDue: @MainActor () -> Bool
    private let mode: @MainActor () -> MainJobGateDiagnostics.RunLoopModeName
    private var depth = 0
    private var open: Open?
    private var observers: [MainRunLoopObserver] = []

    /// A callout being timed.
    private struct Open {
        var callout: MainJobGateDiagnostics.CalloutKind
        var mode: MainJobGateDiagnostics.RunLoopModeName
        var turn: MainJobGateDiagnostics.InputTurn
        var depth: Int
        var startNanos: UInt64
    }

    /// - Parameters:
    ///   - diagnostics: The recorder.
    ///   - observing: False adds no run-loop observer (tests drive ``observe(_:)``).
    ///   - turn: The input of the turn now (the pending-input state, task 021): empty means no input.
    ///   - now: Uptime in nanoseconds.
    ///   - timerDue: Whether a main run-loop timer is due now (after a wake: the wake is a timer's).
    ///   - mode: The main run loop's mode now.
    public init(diagnostics: MainJobGateDiagnostics, observing: Bool = true,
                now: @escaping @MainActor () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
                timerDue: @escaping @MainActor () -> Bool = InputTurnCalloutTimer.mainTimerDue,
                mode: @escaping @MainActor () -> MainJobGateDiagnostics.RunLoopModeName = InputTurnCalloutTimer.mainMode,
                turn: @escaping @MainActor () -> MainJobGateDiagnostics.InputTurn) {
        self.diagnostics = diagnostics
        self.turn = turn
        self.now = now
        self.timerDue = timerDue
        self.mode = mode
        guard observing else { return }
        // First at the stages that end a callout, last at the stages that start one.
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
        case .beforeTimers:
            end()
        case .beforeWaiting:
            end()
            diagnostics.wakeFold()
        case .exit:
            end()
            depth = max(0, depth - 1)
        default:
            break
        }
    }

    private func start(_ callout: MainJobGateDiagnostics.CalloutKind) {
        let input = turn()
        guard !input.isEmpty else {
            open = nil
            return
        }
        open = Open(callout: callout, mode: mode(), turn: input, depth: depth, startNanos: now())
    }

    private func end() {
        guard let started = open else { return }
        open = nil
        // A nested run loop ran inside the callout: its own stages were timed at its depth.
        guard started.depth == depth else { return }
        let nanos = now() &- started.startNanos
        guard nanos >= Self.minimumNanos else { return }
        diagnostics.recordCallout(started.callout, mode: started.mode, turn: started.turn, nanos: nanos)
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
    public nonisolated static func mainMode() -> MainJobGateDiagnostics.RunLoopModeName {
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
