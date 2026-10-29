import CmuxNextWakeups
import Testing

/// The app's one main scheduler owns the one Energy Saver policy and the one main wake queue on it,
/// so every owner that already has the scheduler reaches both without a shared instance.
@MainActor
struct MainWorkSchedulerEnergyTests {
    @Test func theWakeQueueFollowsTheSchedulersPolicy() {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        // Two observers: the wake queue and the scheduler's own frame scheduler, whose ambient clients follow the
        // same policy (FrameScheduler+Energy.swift).
        #expect(work.energy.observerCount == 2, "the wake queue and the scheduler's frames observe this scheduler's source")
        #expect(work.frames.energy === work.energy)
        #expect(work.wakeUps.count == 0)
    }

    @Test func twoSchedulersShareNoEnergyState() {
        let first = MainWorkScheduler(budget: MainFrameBudget())
        let second = MainWorkScheduler(budget: MainFrameBudget())
        first.energy.update(EnergyPolicy(saverReason: .setting))
        #expect(first.energy.policy.isSaver)
        #expect(second.energy.policy == .normal)
        #expect(first.wakeUps !== second.wakeUps)
    }
}
