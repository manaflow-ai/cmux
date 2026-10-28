import CmuxNextWakeups
import Testing

/// The app's one main scheduler owns the one Energy Saver policy and the one main wake queue on it,
/// so every owner that already has the scheduler reaches both without a shared instance.
@MainActor
struct MainWorkSchedulerEnergyTests {
    @Test func theWakeQueueFollowsTheSchedulersPolicy() {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        #expect(work.energy.observerCount == 1, "the wake queue observes this scheduler's source")
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
