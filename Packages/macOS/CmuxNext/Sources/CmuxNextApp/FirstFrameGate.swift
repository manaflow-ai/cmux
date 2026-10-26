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
/// the work always runs.
@MainActor
final class FirstFrameGate {
    private let startup: StartupScheduler
    private let backstop: DemandTimer
    private(set) var isOpen = false

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

    /// The first frame was committed (first call only): the scheduler releases the posted work.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        backstop.cancel()
        startup.firstFrameCommitted()
    }

    /// Opens the gate after `delay` unless a frame opened it first.
    func armBackstop(after delay: Duration) {
        guard !isOpen else { return }
        backstop.schedule(after: delay) { @MainActor [weak self] in self?.open() }
    }

    /// Returns once work posted now would run (the hang reports' first window).
    func opened() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            whenOpen("HangReports.firstWindow") { done.resume() }
        }
    }
}
