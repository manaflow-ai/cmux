public import QuartzCore

extension FrameScheduler {
    /// A scheduler with a fake link on a display clock of its own (tests; budgeted work:
    /// ``MainWorkScheduler/testing(budget:clock:ledger:startup:mediaTime:performTurn:idleTimer:otherLinks:makeLink:)``).
    /// `clock` runs the stall timer; `mediaTime` stands in for `CACurrentMediaTime`, the timebase of frame timestamps.
    public static func testing(clock: any Clock<Duration> = ContinuousClock(), ledger: WakeupLedger = .shared,
                               mediaTime: @escaping @MainActor () -> CFTimeInterval = { CACurrentMediaTime() },
                               makeLink: @escaping LinkFactory) -> FrameScheduler {
        testing(name: "test", clock: clock, ledger: ledger, mediaTime: mediaTime, budget: nil, makeLink: makeLink)
    }

    /// A scheduler named `name` on a one-display clock whose links `makeLink` makes for it.
    static func testing(name: String, clock: any Clock<Duration>, ledger: WakeupLedger,
                        mediaTime: @escaping @MainActor () -> CFTimeInterval, budget: MainFrameBudget?,
                        makeLink: @escaping LinkFactory) -> FrameScheduler {
        let owner = TestLinkOwner()
        let displays = DisplayClock(makeLink: { _, _ in
            guard let scheduler = owner.scheduler else { return nil }
            return makeLink(scheduler)
        }, displayOf: { _ in 1 }, clock: clock, ledger: ledger, mediaTime: mediaTime)
        let scheduler = FrameScheduler(name: name, host: .screen, displays: displays, clock: clock, ledger: ledger, budget: budget)
        owner.scheduler = scheduler
        return scheduler
    }
}

/// Lets a test clock's link factory reach the scheduler it was made for.
@MainActor
private final class TestLinkOwner {
    weak var scheduler: FrameScheduler?
}
