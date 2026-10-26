import CmuxNextWakeups

/// Launch work that waits until the first window's first frame is committed, so it never delays
/// that frame (perf-launch-memory): the updater, SSH and server-reach starts, and the warm-ups for
/// later tabs.
///
/// An adapter onto ``StartupScheduler`` for the delegate's first-frame call sites (p08-startup-012;
/// task 016 turns them into posts and deletes it): ``whenOpen(_:_:)`` is an
/// ``StartupPriority/afterFirstFrame`` main post, so the work runs in post order at the visible
/// class, budgeted per frame behind input, instead of all in the commit's turn. ``open()`` is
/// ``StartupScheduler/firstFrameCommitted()``.
///
/// `AppDelegate` opens it from the first window's `CATransaction` completion. A launch that shows
/// no window (an agent launch, a daemon that never answers) still opens it after the backstop, so
/// the work always runs; the backstop is ``StartupScheduler/firstFrameMissed(_:)``, never a
/// committed frame.
@MainActor
final class FirstFrameGate {
    private let startup: StartupScheduler
    private let backstop: DemandTimer
    /// The posted work is released (by the first frame or the backstop).
    private(set) var isOpen = false
    /// The first frame was committed: the scheduler's first-frame ref ended with that reason.
    private var committed = false
    /// ``opened()`` callers, resumed when the gate opens; the gate never drops them (quit included).
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - startup: The launch's scheduler (its first-frame ref ends at ``open()``).
    ///   - backstop: The deadline that opens the gate when no frame comes; tests inject a manual clock.
    init(startup: StartupScheduler, backstop: DemandTimer = DemandTimer(owner: "FirstFrameGate.backstop")) {
        self.startup = startup
        self.backstop = backstop
    }

    /// Posts `work` to run after the first frame, in post order (at once in the next frames when the
    /// gate is already open).
    ///
    /// - Parameters:
    ///   - name: The task's name in the startup records and signposts (`Domain.step`).
    ///   - work: Main-actor work; no file, network or process work.
    func whenOpen(_ name: StaticString, _ work: @escaping @MainActor @Sendable () -> Void) {
        startup.post(.afterFirstFrame, name, on: .main, work)
    }

    /// The first frame was committed (first call only, also after the backstop opened the gate): the
    /// scheduler releases the posted work and ends its first-frame ref.
    func open() {
        guard !committed else { return }
        committed = true
        backstop.cancel()
        startup.firstFrameCommitted()
        markOpen()
    }

    /// Opens the gate after `delay` unless a frame opened it first.
    ///
    /// - Parameters:
    ///   - delay: How long to wait for the first frame.
    ///   - missed: Read when the deadline passes: why no frame will come (`noWindow`,
    ///     `daemonUnavailable`), or nil when one may still come, so the first-frame ref stays held
    ///     for it or the failsafe.
    func armBackstop(after delay: Duration, missed: @escaping @MainActor () -> StartupInProgressRef.Reason?) {
        guard !isOpen else { return }
        backstop.schedule(after: delay) { @MainActor [weak self] in self?.backstopPassed(missed()) }
    }

    /// Returns once the gate is open (at once when it already is): the hang reports' first window.
    func opened() async {
        guard !isOpen else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in openWaiters.append(done) }
    }

    private func backstopPassed(_ reason: StartupInProgressRef.Reason?) {
        guard !isOpen else { return }
        startup.firstFrameMissed(reason)
        markOpen()
    }

    private func markOpen() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = openWaiters
        openWaiters = []
        for waiter in waiting { waiter.resume() }
    }
}
