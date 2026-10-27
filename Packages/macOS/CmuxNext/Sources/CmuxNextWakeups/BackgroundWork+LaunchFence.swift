import CmuxNextCompat

extension BackgroundWork {
    /// The launch's best-effort fence on one ``BackgroundWork``: raised once by ``BackgroundWork/raiseLaunchFence(cap:clock:)``
    /// before the first launch read is posted, lowered once by ``lower()`` at startup complete (after the first
    /// committed frame and the settle), or by its cap when startup has not completed by then.
    ///
    /// While it is up, posted ``WorkPriority/bestEffort`` and ``WorkPriority/idle`` items stay queued in post order;
    /// higher priorities and awaited items run at once. Chrome raises the same fence for startup
    /// (`ThreadPoolInstance::BeginBestEffortFence`, base/task/thread_pool/thread_pool_instance.h) and lowers it at
    /// startup complete (`EndBestEffortFence`, chrome/browser/after_startup_task_utils.cc). Chrome's backstop is
    /// minutes; cmux caps the hold at ``cap`` (3 s), so a launch that never completes (no window, a page that never
    /// loads) holds saves and caches for 3 s at most (plans/cmux-next/chrome-parity/p02-threads.md, task 114).
    ///
    /// The cap is one one-shot ``DemandTimer`` that exists only while the fence is up: ``lower()`` and
    /// ``BackgroundWork/beginShutdown()`` cancel it. Shutdown also lifts the fence on the lanes, so block-shutdown
    /// items it held run (Chrome's `ThreadPoolImpl::Shutdown` sets `CanRunPolicy::kAll`).
    ///
    /// ```swift
    /// let work = BackgroundWork(hangs: hangWatch)
    /// let fence = work.raiseLaunchFence()      // main(): before any launch read is posted
    /// startup.whenComplete { _ in fence.lower() }
    /// ```
    public final class LaunchFence: Sendable {
        /// The longest the launch fence holds best-effort and idle work.
        public static let cap: Duration = .seconds(3)

        /// The lanes the fence holds.
        public let work: BackgroundWork
        /// Lowers the fence at ``cap`` when nothing lowered it before.
        private let capTimer: DemandTimer
        /// True until the first ``lower()``.
        private let up = Atomic<Bool>(true)

        fileprivate init(work: BackgroundWork, cap: Duration, clock: any Clock<Duration>) {
            self.work = work
            // timer-class-allow: the scheduler's own launch-fence cap, off main; p06 section A: its timers never wait behind the classes they release
            capTimer = DemandTimer(owner: "launch.best-effort-fence.cap", clock: clock)
            work.beginBestEffortFence()
            capTimer.schedule(after: cap) { [weak self] in self?.lower() }
            // After the schedule, so a shutdown that already started cancels the cap here.
            work.holdLaunchCap(capTimer, for: ObjectIdentifier(self))
        }

        /// Whether the fence still holds best-effort and idle work (shutdown lifts it on the lanes either way).
        public var isUp: Bool { up.load(ordering: .acquiring) }

        /// Whether the cap's timer is pending; false once the fence is down or shutdown started.
        var capArmed: Bool { capTimer.isScheduled }

        /// Lowers the fence, the first call only: cancels the cap and starts the held items in post order within each
        /// priority. Any thread.
        ///
        /// - Returns: True when this call lowered the fence; false when it was down already (the cap came first).
        @discardableResult
        public func lower() -> Bool {
            guard up.exchange(false, ordering: .acquiringAndReleasing) else { return false }
            capTimer.cancel()
            work.releaseLaunchCap(for: ObjectIdentifier(self))
            work.endBestEffortFence()
            return true
        }
    }

    /// Raises the launch's best-effort fence, which ``LaunchFence/lower()`` or the cap lowers. The app raises it
    /// once, at its composition root, before the first launch read is posted.
    ///
    /// - Parameters:
    ///   - cap: The longest the fence stays up; default ``LaunchFence/cap``.
    ///   - clock: The clock the cap sleeps on; tests pass a `ManualClock`.
    /// - Returns: The raised fence.
    public func raiseLaunchFence(cap: Duration = LaunchFence.cap,
                                 clock: any Clock<Duration> = ContinuousClock()) -> LaunchFence {
        LaunchFence(work: self, cap: cap, clock: clock)
    }

    /// Records the cap of a raised launch fence, so ``beginShutdown()`` cancels it. After shutdown started the cap
    /// is cancelled at once: the lanes already run every item shutdown keeps.
    fileprivate func holdLaunchCap(_ timer: DemandTimer, for fence: ObjectIdentifier) {
        let closed = state.withLock { state -> Bool in
            if !state.closed { state.launchCaps[fence] = timer }
            return state.closed
        }
        if closed { timer.cancel() }
    }

    /// Forgets the cap of a lowered launch fence.
    fileprivate func releaseLaunchCap(for fence: ObjectIdentifier) {
        state.withLock { _ = $0.launchCaps.removeValue(forKey: fence) }
    }
}
