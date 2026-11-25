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

    /// Runs `steps` in order after the gate opens, one per run-loop pass, each
    /// after that pass's frame commit (`AfterFrameCommit`): none runs inside the
    /// first frame's commit, and input and display get a pass between two steps.
    /// `stop` is read before each step (an app that is terminating).
    public func afterOpen(stop: @escaping @MainActor () -> Bool = { false }, _ steps: [@MainActor () -> Void]) {
        whenOpen { Self.runOnePerPass(steps[...], stop: stop) }
    }

    private static func runOnePerPass(_ steps: ArraySlice<@MainActor () -> Void>, stop: @escaping @MainActor () -> Bool) {
        guard let step = steps.first else { return }
        AfterFrameCommit().run {
            if stop() { return }
            step()
            runOnePerPass(steps.dropFirst(), stop: stop)
        }
    }

    /// Opens the gate (first call only) and runs the waiting work.
    public func open() {
        guard !isOpen else { return }
        isOpen = true
        backstop.cancel()
        let waiting = waiters
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
}

/// One view's launch work held for the turn after the first frame's commit (as ``FirstFrameGate/afterOpen``'s
/// steps), so it neither delays that frame nor runs inside its commit; `runNow` makes it sooner, when the
/// person or an action needs it. Work given while some is held is dropped: the held work reads the view's
/// latest state when it runs (Home's first conversation host, ~90 ms on main: TopHomePageView).
@MainActor
public final class FirstFrameHold {
    private var held: (@MainActor () -> Void)?

    public init() {}

    /// Runs `work` at once when `gate` is nil or open; else holds it until the turn after the gate opens.
    public func run(after gate: FirstFrameGate?, _ work: @escaping @MainActor () -> Void) {
        guard held == nil else { return }
        guard let gate, !gate.isOpen else { return work() }
        held = work
        gate.whenOpen { AfterFrameCommit().run { [weak self] in self?.runNow() } }
    }

    /// Runs the held work now, once (nothing when none is held).
    public func runNow() {
        let work = held
        held = nil
        work?()
    }
}
