import CmuxNextWakeups

/// Launch work that waits until the first window's first frame is committed,
/// so it never delays that frame (perf-launch-memory): the updater, SSH and
/// server-reach starts, and the warm-ups for later tabs.
///
/// `AppDelegate` opens it from the first window's `CATransaction` completion.
/// A launch that shows no window (an agent launch, a daemon that never
/// answers) still opens it after `backstop`, so the work always runs.
@MainActor
final class FirstFrameGate {
    private var waiters: [@MainActor () -> Void] = []
    private(set) var isOpen = false
    private let backstop: DemandTimer

    /// - Parameter backstop: The deadline that opens the gate when no frame
    ///   comes; tests inject a manual clock.
    init(backstop: DemandTimer = DemandTimer(owner: "FirstFrameGate.backstop")) {
        self.backstop = backstop
    }

    /// Runs `work` once the gate is open: at once when it already is, else in
    /// the order the work was added.
    func whenOpen(_ work: @escaping @MainActor () -> Void) {
        if isOpen { work() } else { waiters.append(work) }
    }

    /// Opens the gate (first call only) and runs the waiting work.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        backstop.cancel()
        let waiting = waiters
        waiters.removeAll()
        for work in waiting { work() }
    }

    /// Opens the gate after `delay` unless a frame opened it first.
    func armBackstop(after delay: Duration) {
        guard !isOpen else { return }
        backstop.schedule(after: delay) { @MainActor [weak self] in self?.open() }
    }
}
