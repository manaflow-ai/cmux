public import CmuxNextWakeups

/// Launch work that waits until the first window's first frame is committed, so it never delays
/// that frame (perf-launch-memory, #17587): the updater, SSH and server-reach starts, the warm-ups
/// for later tabs, and every agent chat's web view (the pane draws its saved page meanwhile).
///
/// Once open, the waiting work runs one waiter per ``Step`` (the app's: one per display frame), in
/// the order it was added, never all in the first frame's completion turn: input and a frame
/// commit go between two waiters, so the frame after the first does not stall for all of them.
///
/// The app delegate opens it from the first window's `CATransaction` completion. A launch that
/// shows no window (an agent launch, a daemon that never answers) still opens it after
/// ``armBackstop(after:)``'s delay, so the work always runs.
///
/// ```swift
/// let firstFrame = FirstFrameGate()
/// firstFrame.whenOpen { services.startNonPaintServices() }
/// // ... the first window's CATransaction completion:
/// firstFrame.open()
/// ```
@MainActor
public final class FirstFrameGate {
    /// Schedules `next`, the gate's next step of waiting work, on the main actor.
    public typealias Step = @MainActor (_ next: @escaping @MainActor @Sendable () -> Void) -> Void

    private var waiters: [@MainActor () -> Void] = []
    /// Whether the first window frame was committed (or the backstop passed).
    public private(set) var isOpen = false
    private let backstop: DemandTimer
    private let step: Step

    /// A closed gate.
    /// - Parameters:
    ///   - backstop: The deadline that opens the gate when no frame comes; tests inject a manual clock.
    ///   - step: Schedules each waiter's run once the gate opens, one waiter per step; at once by
    ///     default (a services graph built outside the launch, tests).
    public init(backstop: DemandTimer = DemandTimer(owner: "FirstFrameGate.backstop"), step: @escaping Step = { $0() }) {
        self.backstop = backstop
        self.step = step
    }

    /// A gate with no launch frame to wait for, open from the start: a services graph built outside
    /// the app's launch (tests) runs its launch work at once.
    public static func alreadyOpen() -> FirstFrameGate {
        let gate = FirstFrameGate()
        gate.open()
        return gate
    }

    /// Runs `work` once the gate is open, in the order the work was added: at once when it is open
    /// and every earlier waiter ran, else in a step of its own after them.
    public func whenOpen(_ work: @escaping @MainActor () -> Void) {
        if isOpen, waiters.isEmpty { return work() }
        waiters.append(work)
    }

    /// Opens the gate (first call only) and runs the waiting work, one waiter per ``Step``.
    public func open() {
        guard !isOpen else { return }
        isOpen = true
        backstop.cancel()
        scheduleNext()
    }

    private func scheduleNext() {
        guard !waiters.isEmpty else { return }
        step { [weak self] in self?.runNext() }
    }

    private func runNext() {
        guard !waiters.isEmpty else { return }
        let work = waiters.removeFirst()
        work()
        scheduleNext()
    }

    /// Opens the gate after `delay` unless a frame opened it first.
    public func armBackstop(after delay: Duration) {
        guard !isOpen else { return }
        backstop.schedule(after: delay) { @MainActor [weak self] in self?.open() }
    }
}
