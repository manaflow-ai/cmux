public import CmuxNextWakeups

/// What an idle step's slot allows, from the scheduler's `IdleDeadline`.
public struct ChromiumWarmupSlot: Sendable, Equatable {
    /// The step may hold the main thread past the slot's end: a long idle period, or a step past
    /// its `maxDelay` that runs as background work, with no input response open (Chrome's
    /// `IdleHelper::CanExceedIdleDeadlineIfRequired`, true only in a long idle period). False in a
    /// short period between frames.
    public var mayOverrun: Bool

    public init(mayOverrun: Bool) {
        self.mayOverrun = mayOverrun
    }
}

/// Where ``ChromiumWarmup`` posts its steps: the app's `MainDeadlineScheduler` (its scheduler's idle
/// class, startup phase and deadlines); tests pass a fake that runs the posted steps by hand.
@MainActor
public protocol ChromiumWarmupIdle: AnyObject {
    /// Now (`CLOCK_UPTIME_RAW`, the clock of `InputEventRecord.timestamp`).
    var uptime: Duration { get }

    /// Queues `body` for the main thread's next idle period, never inline. A body that has not run
    /// `maxDelay` after the post runs as background work.
    ///
    /// - Parameters:
    ///   - owner: The task's owner in the scheduler's board.
    ///   - maxDelay: The longest the body waits for idle time.
    ///   - file: The posting file, for the board.
    ///   - line: The posting line, for the board.
    ///   - body: The step, with what its slot allows.
    func postIdleStep(owner: String, maxDelay: Duration, file: StaticString, line: UInt,
                      _ body: @escaping @MainActor (ChromiumWarmupSlot) -> Void)

    /// Runs `action` now when startup settled (`StartupPhase.settled`), else at the settle.
    func whenStartupSettled(_ action: @escaping @MainActor () -> Void)

    /// Runs `action` once, no sooner than `delay` from now, while the returned token is held.
    func after(_ delay: Duration, owner: String, _ action: @escaping @MainActor () -> Void) -> AnyObject
}

extension MainDeadlineScheduler: ChromiumWarmupIdle {
    /// A long idle period starts with up to `IdleScheduler.longPeriodLimit` (50 ms) left; a short
    /// one, between frames, ends 1 ms before the next vsync, so it has less than this at 40 Hz or
    /// faster.
    static let longIdleSlotMinimum: Duration = IdleScheduler.longPeriodLimit / 2

    public func postIdleStep(owner: String, maxDelay: Duration, file: StaticString, line: UInt,
                             _ body: @escaping @MainActor (ChromiumWarmupSlot) -> Void) {
        let budget = work.budget
        work.postIdle(owner: owner, maxDelay: maxDelay, file: file, line: line) { deadline in
            let long = deadline.didTimeout || deadline.timeRemaining >= MainDeadlineScheduler.longIdleSlotMinimum
            body(ChromiumWarmupSlot(mayOverrun: long && !budget.isInputResponseOpen))
        }
    }

    public func whenStartupSettled(_ action: @escaping @MainActor () -> Void) {
        work.startup.whenReached(.settled, action)
    }

    public func after(_ delay: Duration, owner: String, _ action: @escaping @MainActor () -> Void) -> AnyObject {
        let deadline = MainDeadline(owner: owner, workClass: .background, scheduler: self)
        deadline.schedule(after: delay, action)
        return deadline
    }
}
