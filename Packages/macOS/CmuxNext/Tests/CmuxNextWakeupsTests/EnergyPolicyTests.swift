import CmuxNextCompat
@testable import CmuxNextWakeups
import Testing

/// EnergyPolicy and EnergyPolicySource: the derived saver values and change-only
/// observer calls that stop on cancel or release.
@Suite("EnergyPolicy")
struct EnergyPolicyTests {
    @Test func normalPolicyIsUncapped() {
        let policy = EnergyPolicy.normal
        #expect(!policy.isSaver)
        #expect(policy.reason == nil)
        #expect(policy.wakeAlignment == .milliseconds(8))
        #expect(policy.ambientMaxFPS == nil)
        #expect(policy.webFrameRate == nil)
        #expect(policy.pollStretch == 1)
        #expect(!policy.suspended && !policy.screensAsleep && !policy.onBattery)
    }

    @Test(arguments: EnergyPolicy.Reason.allCases)
    func saverPolicyFollowsChromesBatterySaver(reason: EnergyPolicy.Reason) {
        let policy = EnergyPolicy(saverReason: reason, onBattery: true)
        #expect(policy.isSaver)
        #expect(policy.reason == reason)
        #expect(policy.wakeAlignment == .milliseconds(32))
        #expect(policy.ambientMaxFPS == 30)
        #expect(policy.webFrameRate == 30)
        #expect(policy.pollStretch == 4)
        #expect(policy.onBattery)
    }

    @Test func rawInputsDoNotTurnTheSaverOn() {
        let policy = EnergyPolicy(suspended: true, screensAsleep: true, onBattery: true)
        #expect(!policy.isSaver)
        #expect(policy.wakeAlignment == .milliseconds(8))
        #expect(policy.suspended && policy.screensAsleep && policy.onBattery)
    }

    @Test func sourceTellsObserversOnlyOnChange() {
        let source = EnergyPolicySource()
        let seen = Mutex<[EnergyPolicy]>([])
        let observation = source.observe { policy in seen.withLock { $0.append(policy) } }
        let saver = EnergyPolicy(saverReason: .lowPowerMode)

        source.update(.normal)
        source.update(saver)
        source.update(saver)

        #expect(source.policy == saver)
        #expect(seen.withLock { $0 } == [saver])
        observation.cancel()
    }

    @Test func observersReadTheNewPolicyFromTheSource() {
        let source = EnergyPolicySource()
        let read = Mutex<EnergyPolicy?>(nil)
        let observation = source.observe { [source] _ in
            let policy = source.policy
            read.withLock { $0 = policy }
        }
        let saver = EnergyPolicy(saverReason: .setting)

        source.update(saver)

        #expect(read.withLock { $0 } == saver)
        observation.cancel()
    }

    @Test func cancelledOrReleasedObservationsStop() {
        let source = EnergyPolicySource()
        let calls = Mutex(0)
        let kept = source.observe { _ in calls.withLock { $0 += 1 } }
        var released: EnergyPolicyObservation? = source.observe { _ in calls.withLock { $0 += 1 } }
        #expect(source.observerCount == 2)
        #expect(released != nil)

        released = nil
        kept.cancel()
        kept.cancel()
        source.update(EnergyPolicy(saverReason: .battery))

        #expect(source.observerCount == 0)
        #expect(calls.withLock { $0 } == 0)
    }
}
