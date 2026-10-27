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
/// the completion, after the `startup_complete` marks. Its cap (``BackgroundWork/LaunchFence/cap``,
/// 3 s) lowers it first when startup completes later; the completion then marks
/// ``fenceCappedMark``.
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
    /// ``LaunchOrder`` made on it lowers it at startup complete, or its cap does.
    public struct BestEffortFence: Sendable {
        /// The raised fence; the order lowers it.
        public let launch: BackgroundWork.LaunchFence
        /// The lanes the fence holds.
        public var background: BackgroundWork { launch.work }

        /// Raises the fence on `background`, capped at `cap` on `clock`.
        ///
        /// - Parameters:
        ///   - background: The app's lanes.
        ///   - cap: The longest the fence holds; default ``BackgroundWork/LaunchFence/cap``.
        ///   - clock: The clock the cap sleeps on; tests pass a manual one.
        public init(raisingOn background: BackgroundWork, cap: Duration = BackgroundWork.LaunchFence.cap,
                    clock: any Clock<Duration> = ContinuousClock()) {
            launch = background.raiseLaunchFence(cap: cap, clock: clock)
        }
    }

    /// The mark the completion sends when the cap lowered the fence first. It stays out of the
    /// `startup_complete.` namespace, which holds only the completion's reason (bench-startup.py).
    nonisolated public static let fenceCappedMark = "launch.best_effort_fence_capped"

    /// The app's one main-thread scheduler (budget, input check, task signposts, starvation guard);
    /// its ``MainWorkScheduler/startup`` phase is the launch's.
    public let mainWork: MainWorkScheduler
    /// The one owner of launch order: posts, refs and the completion.
    public let startup: StartupScheduler
    #if CMUX_PGO_PROFILE
    /// The profile build's flushes (p08-startup-103): launch.profraw at startup complete; `debug.pgo_flush`
    /// writes rest.profraw before quit.
    public let profileFlush: ProfileFlush
    #endif

    /// An order on schedulers made elsewhere (tests: hand-run frames and main hop); `startup` must
    /// post its lane work to `fence`'s lanes. At startup complete it marks `startup_complete.<reason>`
    /// (an instant mark, as task 007 sends the temperature) and then `startup_complete`, so a reader
    /// that waits for `startup_complete` has the reason too; then it lowers the fence, so the held
    /// idle and best-effort items start, or marks ``fenceCappedMark`` when the cap lowered it first.
    /// A quit before completion never lowers it (shutdown lifts it).
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
        startup.whenComplete { [launch = fence.launch] completion in
            mark("startup_complete.\(completion.reason)")
            mark("startup_complete")
            if !launch.lower() { mark(Self.fenceCappedMark) }
        }
        #if CMUX_PGO_PROFILE
        profileFlush = ProfileFlush(launchedOn: fence.background)
        profileFlush.writeLaunchProfile(when: startup)
        #endif
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
    ///   - startupTag: The launch's tag `main()` made first and gave the main-thread watchdog: the startup
    ///     scheduler keeps its running task and phase there, so a launch stall names them (p08-startup-088).
    ///   - mark: Records a launch mark (`launch.revealed`, `launch.settled`, `startup_complete`).
    public init(fence: BestEffortFence, board: MainTaskBoard = MainTaskBoard(), input: any InputObserving,
                startupTag: StartupTaskTag = StartupTaskTag(), mark: @escaping @MainActor (String) -> Void) {
        // One display link per display, shared by the app, window and budgeted frame schedulers.
        let displays = DisplayClock()
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
        // The quiet before a long idle period starts again at each key, click, scroll or drag.
        pending.onInputDispatched = { [weak idle = mainWork.idle] in idle?.noteInput() }
        // The app and window schedulers run on that clock and follow the app's one Energy Saver policy.
        FrameScheduler.install(displays: displays, energy: mainWork.energy)
        starvation.watch(mainWork.frames, FrameScheduler.app)
        self.init(fence: fence, mainWork: mainWork,
                  startup: StartupScheduler(mainWork: mainWork, background: fence.background, clock: ContinuousClock(),
                                            log: .signposted(tag: startupTag)), mark: mark)
    }
}
