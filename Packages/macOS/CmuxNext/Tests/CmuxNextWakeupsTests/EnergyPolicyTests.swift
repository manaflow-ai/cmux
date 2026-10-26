import CmuxNextCompat
@testable import CmuxNextWakeups
import Testing

/// EnergyPolicy and EnergyPolicySource (p14-energy-023): the derived saver values, change-only
/// observer calls, what FrameScheduler gives ambient clients, and DemandTimer's leeway.
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

    @Test func normalDefaultIsAFreshSourceEachTime() {
        let first = EnergyPolicySource.normal
        first.update(EnergyPolicy(saverReason: .setting))
        #expect(EnergyPolicySource.normal.policy == .normal)
    }

    @Test func ambientFramesFollowThePolicy() {
        #expect(FrameScheduler.AmbientFrames(.normal) == .uncapped)
        #expect(FrameScheduler.AmbientFrames(EnergyPolicy(saverReason: .battery)) == .capped(30))
        #expect(FrameScheduler.AmbientFrames(EnergyPolicy(screensAsleep: true)) == .stopped)
        #expect(FrameScheduler.AmbientFrames(EnergyPolicy(saverReason: .battery, screensAsleep: true)) == .stopped)
    }

    @Test @MainActor func schedulerReadsItsSourceNow() {
        let energy = EnergyPolicySource()
        let scheduler = FrameScheduler.testing(energy: energy) { _ in nil }
        #expect(scheduler.ambientFrames == .uncapped)
        energy.update(EnergyPolicy(saverReason: .thermal, onBattery: true))
        #expect(scheduler.ambientFrames == .capped(30))
        energy.update(EnergyPolicy(screensAsleep: true))
        #expect(scheduler.ambientFrames == .stopped)
        scheduler.invalidate()
    }

    @Test @MainActor func installPutsTheAppSchedulerOnTheSource() {
        let previous = FrameScheduler.app.energy
        let energy = EnergyPolicySource(EnergyPolicy(saverReason: .setting))
        FrameScheduler.install(energy: energy)
        #expect(FrameScheduler.app.energy === energy)
        #expect(FrameScheduler.app.ambientFrames == .capped(30))
        FrameScheduler.install(energy: previous)
    }

    @Test(arguments: [(EnergyPolicy.normal, Duration.milliseconds(8)),
                      (EnergyPolicy(saverReason: .lowPowerMode), Duration.milliseconds(32))])
    func demandTimerSleepsWithThePolicysLeeway(policy: EnergyPolicy, tolerance: Duration) async {
        let clock = ToleranceClock()
        let timer = DemandTimer(owner: "energy-test", clock: clock, ledger: WakeupLedger(uptime: { 0 }),
                                energy: EnergyPolicySource(policy))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            timer.schedule(after: .milliseconds(100)) { done.resume() }
        }
        #expect(clock.tolerances == [tolerance])
    }

    @Test func demandTimerReadsTheSourceAtEachSchedule() async {
        let clock = ToleranceClock()
        let energy = EnergyPolicySource()
        let timer = DemandTimer(owner: "energy-test", clock: clock, ledger: WakeupLedger(uptime: { 0 }), energy: energy)
        for policy in [EnergyPolicy.normal, EnergyPolicy(saverReason: .setting)] {
            energy.update(policy)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                timer.schedule(after: .milliseconds(200)) { done.resume() }
            }
        }
        #expect(clock.tolerances == [.milliseconds(8), .milliseconds(32)])
    }
}

/// A clock whose sleeps return at once and record the tolerance they were asked for.
private final class ToleranceClock: Clock, Sendable {
    typealias Instant = ContinuousClock.Instant

    private let base = ContinuousClock()
    private let asked = Mutex<[Duration?]>([])

    var now: Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }
    var tolerances: [Duration?] { asked.withLock { $0 } }

    // concurrency-allow: the Clock protocol's own requirement; it returns at once (no thread waits, no timer).
    @concurrent func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        asked.withLock { $0.append(tolerance) }
    }
}
