public import CmuxNextWakeups

/// The launch's order owners, made once in the app's `main()` and passed by init (p08-startup-012,
/// plans/cmux-next/chrome-parity/p08-startup.md section 3B): the main-thread scheduler with its
/// startup phase, and the ``StartupScheduler`` every launch task is posted to.
///
/// Chrome makes the same pair before the UI thread runs: `BrowserTaskExecutor` with its startup
/// queues (content/browser/scheduler/browser_task_executor.cc) and the after-startup state
/// (chrome/browser/after_startup_task_utils.cc), which lowers the thread pool's best-effort fence
/// (`ThreadPoolInstance::EndBestEffortFence`, base/task/thread_pool/thread_pool_instance.h) at
/// startup complete. `main()` raises that fence on the app's ``BackgroundWork`` as soon as the
/// lanes exist; the order lowers it at the completion, after the `startup_complete` marks.
///
/// ```swift
/// let work = BackgroundWork(hangs: hangWatch)
/// work.beginBestEffortFence()                  // main(): before any launch read is posted
/// let order = LaunchOrder(background: work) { DebugTimings.markLaunch($0) }
/// let restored = order.restoreHold { daemon.startup.isUnavailable }
/// windows.onRestored = { restored(windows.controllers.count) }
/// ```
@MainActor
public struct LaunchOrder {
    /// The app's one main-thread scheduler (budget, input check, task signposts, starvation guard);
    /// its ``MainWorkScheduler/startup`` phase is the launch's.
    public let mainWork: MainWorkScheduler
    /// The one owner of launch order: posts, refs and the completion.
    public let startup: StartupScheduler

    /// An order on schedulers made elsewhere (tests: hand-run frames and main hop).
    public init(mainWork: MainWorkScheduler, startup: StartupScheduler) {
        self.mainWork = mainWork
        self.startup = startup
    }

    /// The app's order: the display clock, the startup phase, the main-thread scheduler and the startup
    /// scheduler, in that order. Call it after the application object exists (the display clock reads
    /// screens) and before the delegate.
    ///
    /// - Parameters:
    ///   - background: The app's lanes, whose best-effort fence `main()` raised; it is lowered at
    ///     startup complete (``endFenceAtCompletion(_:mark:)``).
    ///   - mark: Records a launch mark (`launch.revealed`, `launch.settled`, `startup_complete`).
    public init(background: BackgroundWork, mark: @escaping @MainActor (String) -> Void) {
        // One display link per display, shared by the app, window and budgeted frame schedulers.
        let displays = DisplayClock()
        FrameScheduler.install(displays: displays)
        // The launch's phases (p06-scheduler-006/007): background work waits for the reveal, idle
        // work for the settle. The marks are queued first, so each shows before the held work it opens.
        let phase = StartupPhase()
        phase.whenReached(.revealed) { mark("launch.revealed") }
        phase.whenReached(.settled) { mark("launch.settled") }
        let starvation = RenderStarvationGuard(holdsWork: false, signposts: true) // holds work once FeatureList is in the app (p12-perf-process-091)
        let mainWork = MainWorkScheduler(budget: MainFrameBudget(input: SessionInputPending(), signposts: true, starvation: starvation),
                                         displays: displays, startup: phase)
        starvation.watch(mainWork.frames, FrameScheduler.app)
        self.init(mainWork: mainWork, startup: StartupScheduler(mainWork: mainWork, background: background, clock: ContinuousClock()))
        endFenceAtCompletion(background, mark: mark)
    }

    /// At startup complete: marks `startup_complete.<reason>` (an instant mark, as task 007 sends the
    /// temperature) and then `startup_complete`, so a reader that waits for `startup_complete` has the
    /// reason too; then lowers `background`'s best-effort fence, so its held idle and best-effort items
    /// start. A quit before completion never lowers it (shutdown lifts it).
    ///
    /// - Parameters:
    ///   - background: The lanes whose fence `main()` raised.
    ///   - mark: Records a launch mark.
    public func endFenceAtCompletion(_ background: BackgroundWork, mark: @escaping @MainActor (String) -> Void) {
        startup.whenComplete { completion in
            mark("startup_complete.\(completion.reason)")
            mark("startup_complete")
            background.endBestEffortFence()
        }
    }

    /// Holds startup open across the session restore (Chrome's session-restore
    /// `StartupInProgressRef`, chrome/browser/after_startup_task_utils.cc): call the result with the
    /// window count once restore ran. A daemon that never loads never restores, so the launch phase's
    /// settle ends the ref too.
    ///
    /// - Parameter daemonUnavailable: Whether the local daemon could not be reached.
    /// - Returns: Ends the ref (first call only) with the reason the restore had.
    public func restoreHold(daemonUnavailable: @escaping @MainActor () -> Bool) -> @MainActor (_ windowCount: Int) -> Void {
        let restore = startup.hold("WindowManager.restore")
        let phase = mainWork.startup
        phase.whenReached(.settled) { [weak phase] in
            restore.release(Self.settledReason(phase?.settleCause, daemonUnavailable: daemonUnavailable()))
        }
        return { windowCount in restore.release(Self.restoreReason(windowCount: windowCount, daemonUnavailable: daemonUnavailable())) }
    }

    /// Why the restore ref ends when restore ran: no daemon, no window, or the windows are restored.
    private static func restoreReason(windowCount: Int, daemonUnavailable: Bool) -> StartupInProgressRef.Reason {
        if daemonUnavailable { return .daemonUnavailable }
        return windowCount == 0 ? .noWindow : .restoreFinished
    }

    /// Why the restore ref ends when the launch phase settled before restore ran: its failsafe, or a
    /// daemon that never loaded (StartupReferences marks restore done for it).
    private static func settledReason(_ cause: StartupPhase.SettleCause?, daemonUnavailable: Bool) -> StartupInProgressRef.Reason {
        if cause == .failsafe { return .failsafe }
        return daemonUnavailable ? .daemonUnavailable : .launchPhaseSettled
    }
}
