public import CmuxNextInputCore
import CmuxNextSignposts
public import CmuxNextWakeups

/// The launch's order owners, made once in the app's `main()` and passed by init (p08-startup-012,
/// plans/cmux-next/chrome-parity/p08-startup.md section 3B): the main-thread scheduler with its
/// startup phase, and the ``StartupScheduler`` every launch task is posted to.
///
/// Chrome makes the same pair before the UI thread runs: `BrowserTaskExecutor` with its startup
/// queues (content/browser/scheduler/browser_task_executor.cc) and the after-startup state
/// (chrome/browser/after_startup_task_utils.cc), which lowers the thread pool's best-effort fence
/// (`ThreadPoolInstance::EndBestEffortFence`, base/task/thread_pool/thread_pool_instance.h) at
/// startup complete. The fence is one pair: ``BestEffortFence`` raises it on the app's
/// ``BackgroundWork`` as soon as the lanes exist, and the order made on that fence lowers it at
/// the completion, after the `startup_complete` marks.
///
/// ```swift
/// let work = BackgroundWork(hangs: hangWatch)
/// let fence = LaunchOrder.BestEffortFence(raisingOn: work)   // main(): before any launch read is posted
/// let inputTap = InputEventTap()
/// let order = LaunchOrder(fence: fence, input: inputTap) { DebugTimings.markLaunch($0) }
/// ```
@MainActor
public struct LaunchOrder {
    /// The best-effort fence `main()` raises before the first launch read is posted (Chrome's
    /// `ThreadPoolInstance::BeginBestEffortFence`): idle and best-effort lane work waits until the
    /// ``LaunchOrder`` made on it lowers it at startup complete.
    public struct BestEffortFence: Sendable {
        /// The lanes the fence holds.
        public let background: BackgroundWork

        /// Raises the fence on `background`.
        public init(raisingOn background: BackgroundWork) {
            background.beginBestEffortFence()
            self.background = background
        }
    }

    /// The app's one main-thread scheduler (budget, input check, task signposts, starvation guard);
    /// its ``MainWorkScheduler/startup`` phase is the launch's.
    public let mainWork: MainWorkScheduler
    /// The one owner of launch order: posts, refs and the completion.
    public let startup: StartupScheduler

    /// An order on schedulers made elsewhere (tests: hand-run frames and main hop); `startup` must
    /// post its lane work to `fence`'s lanes. At startup complete it marks `startup_complete.<reason>`
    /// (an instant mark, as task 007 sends the temperature) and then `startup_complete`, so a reader
    /// that waits for `startup_complete` has the reason too; then it lowers the fence, so the held
    /// idle and best-effort items start. A quit before completion never lowers it (shutdown lifts it).
    ///
    /// - Parameters:
    ///   - fence: The fence `main()` raised.
    ///   - mainWork: The main-thread scheduler.
    ///   - startup: The startup scheduler on `mainWork`.
    ///   - mark: Records a launch mark.
    public init(fence: BestEffortFence, mainWork: MainWorkScheduler, startup: StartupScheduler,
                mark: @escaping @MainActor (String) -> Void) {
        self.mainWork = mainWork
        self.startup = startup
        startup.whenComplete { [background = fence.background] completion in
            mark("startup_complete.\(completion.reason)")
            mark("startup_complete")
            background.endBestEffortFence()
        }
    }

    /// The app's order: the display clock, the startup phase, the main-thread scheduler and the startup
    /// scheduler, in that order. Call it after the application object exists (the display clock reads
    /// screens) and before the delegate.
    ///
    /// - Parameters:
    ///   - fence: The fence `main()` raised on the app's lanes; lowered at startup complete.
    ///   - board: The main task board the budget publishes running work on; `main()` gives the same one to its
    ///     `BackgroundWork`, whose debug check reads the open input work there (p02-threads 112).
    ///   - input: The app's one input tap (p04-input.md 3 (A)): the budget's pending-input check observes it.
    ///   - mark: Records a launch mark (`launch.revealed`, `launch.settled`, `startup_complete`).
    public init(fence: BestEffortFence, board: MainTaskBoard = MainTaskBoard(), input: any InputObserving,
                mark: @escaping @MainActor (String) -> Void) {
        // One display link per display, shared by the app, window and budgeted frame schedulers.
        let displays = DisplayClock()
        FrameScheduler.install(displays: displays)
        // One frame.commit per commit, and each key echo's present at its display's vsync (p09-observability 037).
        displays.presents.pendingCommits = { TypingLatencyProbe.shared.takePresentCommits() }
        displays.presents.observeCommits()
        // The launch's phases (p06-scheduler-006/007): background work waits for the reveal, idle
        // work for the settle. The marks are queued first, so each shows before the held work it opens.
        let phase = StartupPhase()
        phase.whenReached(.revealed) { mark("launch.revealed") }
        phase.whenReached(.settled) { mark("launch.settled") }
        let starvation = RenderStarvationGuard(holdsWork: false, signposts: true) // holds work once FeatureList is in the app (p12-perf-process-091)
        let pending = SessionInputPending(events: WindowServerInputEvents(input: input))
        let mainWork = MainWorkScheduler(budget: MainFrameBudget(input: pending, board: board, signposts: true, starvation: starvation),
                                         displays: displays, startup: phase)
        starvation.watch(mainWork.frames, FrameScheduler.app)
        self.init(fence: fence, mainWork: mainWork,
                  startup: StartupScheduler(mainWork: mainWork, background: fence.background, clock: ContinuousClock()), mark: mark)
    }
}
