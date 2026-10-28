import CmuxNextWakeups

/// libghostty's app tick as a task on the main-thread board, owner `ghostty.tick`
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section E, task 218): the watchdog names it in a
/// stall, and `debug.main_budget` shows its run times per class.
///
/// A tick runs in the ``MainWorkClass/input`` class while a key a terminal took waits for its frame:
/// from the key until the input response it opened closes, at the end of the first link-tick render
/// pass after it (``MainFrameBudget/isInputResponseOpen``), and never past ``keyWindowNanos``. That tick parses the echo the person waits
/// for. Every other tick is ``MainWorkClass/frame`` work. Chrome raises the compositor's priority the
/// same way while a discrete input waits for its paint (`MainThreadSchedulerImpl`,
/// third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc,
/// `RenderingPrioritizationState::kWaitingForInputResponse`).
///
/// Wakeups still merge before they reach it: the runtime's pending flag keeps one tick queued however
/// many wakeups came (``ghosttyWakeup(_:)``).
///
/// ```swift
/// let ticks = GhosttyTickClass(work: mainWork)
/// ticks.noteTerminalKey()                        // TerminalSurfaceView.keyDown
/// ticks.run(posted: post) { ghostty_app_tick(app) } // input class until the key's frame, then frame
/// ```
@MainActor
final class GhosttyTickClass {
    /// The tick's owner on the board.
    static let owner = "ghostty.tick"

    /// The longest a key keeps the tick in the input class: the input response's own cap (Chrome's
    /// rendering-starvation threshold), so a later response no terminal key opened never counts.
    static let keyWindowNanos: UInt64 = 100_000_000

    /// The app's main-thread scheduler: the tick runs on its budget's board.
    let work: MainWorkScheduler
    private let taskOwner: MainTaskOwner
    private let now: () -> UInt64
    /// When a terminal last took a key whose frame no tick has seen yet (``now`` time).
    private var keyAt: UInt64?

    private var budget: MainFrameBudget { work.budget }

    /// - Parameters:
    ///   - work: The app's main-thread scheduler.
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds (tests: a clock they move).
    init(work: MainWorkScheduler, now: @escaping () -> UInt64 = { MainTaskPost.uptimeNanos() }) {
        self.work = work
        self.now = now
        taskOwner = work.board.owner(Self.owner)
    }

    /// A terminal took a key: ticks run as input until that key's frame.
    func noteTerminalKey() {
        keyAt = now()
    }

    /// The class a tick that starts now runs in.
    func classForTick() -> MainWorkClass {
        guard let keyAt else { return .frame }
        if now() &- keyAt < Self.keyWindowNanos, budget.isInputResponseOpen { return .input }
        self.keyAt = nil
        return .frame
    }

    /// Runs `tick` as one board task of ``classForTick()``.
    ///
    /// - Parameters:
    ///   - post: When the wakeup that queued it came (nil: run time only).
    ///   - tick: The app tick.
    func run(posted post: MainTaskPost?, _ tick: () -> Void) {
        budget.run(classForTick(), owner: taskOwner, posted: post, tick)
    }
}
