/// A layout plan applied in the main run loop's current turn and not committed yet
/// (plans/cmux-next/chrome-parity/p03-rendering.md, task 116: no in-process CEF pump slice starts
/// inside a plan apply). The plan's owner notes each apply: a layout change of a shown screen, and each
/// frame a pane motion steps on the CPU. A CLI, socket or agent change applies its plan with no input
/// turn, so a person's input signals alone do not cover it.
///
/// The apply commits in its turn's before-waiting phase (the Core Animation commit), where
/// ``MainTurnMeter`` ends the turn; the next turn starts a new number. So the apply is open while the
/// turn number is the apply's, as Chrome's main thread runs no other long task between a main frame's
/// update and its commit (third_party/blink/renderer/platform/scheduler/main_thread/
/// main_thread_scheduler_impl.cc, rendering prioritization). The meter must observe the main run loop
/// (the composition root's `budget.turns.observe()`).
///
/// ```swift
/// // The layout owner, after it applied a plan:
/// mainWork.planApplies.noteApplied()
/// // The CEF pump, before a slice:
/// if mainWork.planApplies.isOpen { /* hold the pass for the next frame */ }
/// ```
@MainActor
public final class PlanApplyTurn {
    private let turns: MainTurnMeter
    /// The turn of the last apply; nil before any.
    private var appliedIn: UInt64?

    /// - Parameter turns: The app's turn meter (``MainFrameBudget/turns``).
    public init(turns: MainTurnMeter) {
        self.turns = turns
    }

    /// A plan was applied in this turn: it commits at the turn's end.
    public func noteApplied() {
        appliedIn = turns.turnNumber
    }

    /// Whether a plan applied in this turn has not committed yet.
    public var isOpen: Bool {
        appliedIn == turns.turnNumber
    }
}
