public import CmuxNextWakeups

/// Launch work that waits until the first window's first frame is committed,
/// so it never delays that frame (perf-launch-memory): the updater, SSH and
/// server-reach starts, and the warm-ups for later tabs.
///
/// The app (`AppDelegate`) opens it from the first window's `CATransaction` completion.
/// A launch that shows no window (an agent launch, a daemon that never
/// answers) still opens it after `backstop`, so the work always runs.
@MainActor
public final class FirstFrameGate {
    private var waiters: [@MainActor () -> Void] = []
    /// Work that runs ahead of `waiters` when the gate opens (``whenOpenFirst(_:)``).
    private var firstWaiters: [@MainActor () -> Void] = []
    public private(set) var isOpen = false
    private let backstop: DemandTimer

    /// - Parameter backstop: The deadline that opens the gate when no frame
    ///   comes; tests inject a manual clock.
    public init(backstop: DemandTimer = DemandTimer(owner: "FirstFrameGate.backstop")) {
        self.backstop = backstop
    }

    /// Runs `work` once the gate is open: at once when it already is, else in
    /// the order the work was added.
    public func whenOpen(_ work: @escaping @MainActor () -> Void) {
        if isOpen { work() } else { waiters.append(work) }
    }

    /// Runs `work` once the gate is open, as ``whenOpen(_:)`` does, but inside ``open()`` ahead of all
    /// ``whenOpen(_:)`` work, also work added before it: for the step the shown page waits on (Chromium's
    /// framework map and launch prep under a restored chat), which otherwise began only after the updater,
    /// the feeds and the later tabs' warm-ups added at launch had run on main.
    public func whenOpenFirst(_ work: @escaping @MainActor () -> Void) {
        if isOpen { work() } else { firstWaiters.append(work) }
    }

    /// Opens the gate (first call only) and runs the waiting work: ``whenOpenFirst(_:)`` work first, then
    /// ``whenOpen(_:)`` work, each in the order it was added.
    public func open() {
        guard !isOpen else { return }
        isOpen = true
        backstop.cancel()
        let waiting = firstWaiters + waiters
        firstWaiters.removeAll()
        waiters.removeAll()
        for work in waiting { work() }
    }

    /// Opens the gate after `delay` unless a frame opened it first.
    public func armBackstop(after delay: Duration) {
        guard !isOpen else { return }
        backstop.schedule(after: delay) { @MainActor [weak self] in self?.open() }
    }

    /// Returns once the gate is open (at once when it already is).
    public func opened() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in whenOpen { done.resume() } }
    }

    /// Returns once the gate is open, as ``opened()`` does, resumed ahead of all ``whenOpen(_:)`` work
    /// (``whenOpenFirst(_:)``): a waiter off the main actor starts at once when the frame is in.
    public func openedFirst() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in whenOpenFirst { done.resume() } }
    }
}
