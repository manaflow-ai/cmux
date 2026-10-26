public import CmuxNextWakeups

/// A one-shot main-thread deadline of a shared component: a toast's time on screen, a tooltip's hover delay, a
/// quit save's limit. In the app it is a ``MainDeadline`` (its action is posted in its class, behind the person's
/// input); a component made without the app's deadline scheduler, and tests on a manual clock, get a
/// ``ComponentDeadlines/clock(_:)`` one.
@MainActor
public protocol ComponentDeadline: AnyObject {
    /// True from a schedule until its action runs or it is cancelled.
    var isScheduled: Bool { get }
    /// Runs `action` once, no sooner than `delay` from now, replacing any pending deadline.
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    /// Drops the pending deadline.
    func cancel()
}

extension MainDeadline: ComponentDeadline {}

/// Where a component's deadlines come from: the app's one deadline scheduler (``on(_:)``), or a clock
/// (``clock(_:)``). Chromium's components take their timers' task runner from their owner
/// (`base::OneShotTimer::SetTaskRunner`, base/timer/timer.h); the composition root hands this in the same way.
///
/// ```swift
/// CmuxToastCenter.shared.deadlines = .on(services.mainDeadlines)
/// let hide = deadlines.deadline(owner: "toast", workClass: .visible)
/// hide.schedule(after: .seconds(6)) { [weak self] in self?.end(serial, .timeout) }
/// ```
@MainActor
public struct ComponentDeadlines {
    private let make: @MainActor (_ owner: String, _ workClass: BudgetedWorkClass, _ file: StaticString,
                                  _ line: UInt) -> any ComponentDeadline

    /// ``MainDeadline``s on the app's deadline scheduler, flexible (a person waits on none of them to the
    /// millisecond, and none may wait for its node to show).
    public static func on(_ scheduler: MainDeadlineScheduler) -> ComponentDeadlines {
        ComponentDeadlines { owner, workClass, file, line in
            MainDeadline(owner: owner, workClass: workClass, scheduler: scheduler, file: file, line: line)
        }
    }

    /// Deadlines asleep on `clock`: a component no composition root reached, and tests that step a manual clock.
    public static func clock(_ clock: any Clock<Duration>) -> ComponentDeadlines {
        ComponentDeadlines { owner, _, _, _ in ClockDeadline(owner: owner, clock: clock) }
    }

    /// A new deadline for `owner`, whose action runs in `workClass` (on a clock: on the main actor at once).
    ///
    /// - Parameters:
    ///   - owner: The board's and the ledger's name for it (`toast`, `tooltip.intent`).
    ///   - workClass: `visible` for what shows on screen, `userBlocking` for what a person waits on, `background`
    ///     for what nobody sees.
    ///   - file: The posting file of its action (leave the default).
    ///   - line: The posting line of its action (leave the default).
    public func deadline(owner: String, workClass: BudgetedWorkClass, file: StaticString = #fileID,
                         line: UInt = #line) -> any ComponentDeadline {
        make(owner, workClass, file, line)
    }
}

/// A ``ComponentDeadline`` asleep on a clock (``ComponentDeadlines/clock(_:)``).
@MainActor
final class ClockDeadline: ComponentDeadline {
    private let timer: DemandTimer
    private var action: (@MainActor () -> Void)?
    /// Bumped by every schedule and cancel, so the fire of an older plan does nothing.
    private var generation: UInt64 = 0

    init(owner: String, clock: any Clock<Duration>) {
        // timer-class-allow: the clock path, for a component with no deadline scheduler (tests step a manual clock);
        // the app's components run on MainDeadline (ComponentDeadlines.on)
        timer = DemandTimer(owner: owner, clock: clock)
    }

    var isScheduled: Bool { action != nil }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        generation &+= 1
        let planned = generation
        self.action = action
        timer.scheduleOnMain(after: delay) { [weak self] in self?.fire(planned) }
    }

    func cancel() {
        generation &+= 1
        action = nil
        timer.cancel()
    }

    private func fire(_ planned: UInt64) {
        guard planned == generation, let action else { return }
        self.action = nil
        action()
    }
}
