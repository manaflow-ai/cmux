import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// DemandTimer's delay policy and tolerance: each sleep asks the ``WakeLeeway``
/// window of the timer's ``DelayPolicy`` (Chromium's `subtle::DelayPolicy`, base/task/delay_policy.h),
/// on the injected Energy Saver alignment, and the deadline itself never moves.
@Suite("DemandTimer leeway")
struct DemandTimerLeewayTests {
    /// One timer on a manual clock with a private ledger, and the fires of its action in order.
    private struct Rig {
        let clock = ManualClock()
        let fires: AsyncStream<Duration>
        private let fired: AsyncStream<Duration>.Continuation
        let ledger = WakeupLedger()
        let timer: DemandTimer

        init(policy: DelayPolicy = .flexibleNoSooner, energy: EnergyPolicySource? = nil) {
            let stream = AsyncStream.makeStream(of: Duration.self)
            fires = stream.stream
            fired = stream.continuation
            timer = DemandTimer(owner: "test.demand-timer.leeway", policy: policy, clock: clock,
                                ledger: ledger, energy: energy)
        }

        /// How many deadlines have fired so far (each fire is one ledger record).
        var fireCount: UInt64 {
            ledger.snapshot().filter { $0.owner == timer.owner }.reduce(0) { $0 + $1.count }
        }

        /// Schedules a fire after `delay` and returns the sleep the timer asked of the clock.
        func schedule(after delay: Duration, tolerance: Duration? = nil) async throws -> ManualClock.SleepRequest? {
            let clock = clock
            let fired = fired
            timer.schedule(after: delay, tolerance: tolerance) { fired.yield(clock.now.offset) }
            try await clock.waitForSleeper()
            return clock.sleepRequests.last
        }

        /// The clock offset the next fire ran at.
        func nextFire() async -> Duration? {
            var iterator = fires.makeAsyncIterator()
            return await iterator.next()
        }
    }

    @Test func aFiveSecondFlexibleDeadlineAsksHalfASecond() async throws {
        let rig = Rig()
        let request = try await rig.schedule(after: .seconds(5))
        #expect(request?.deadline.offset == .seconds(5))
        #expect(request?.tolerance == .milliseconds(500))
    }

    @Test func aPreciseTwentyMillisecondDeadlineAsksNoTolerance() async throws {
        let rig = Rig(policy: .precise)
        let request = try await rig.schedule(after: .milliseconds(20))
        #expect(request?.deadline.offset == .milliseconds(20))
        #expect(request?.tolerance == .zero)
    }

    @Test func aPreciseDeadlineFromThirtySixMillisecondsOnIsFlexible() async throws {
        let rig = Rig(policy: .precise)
        let request = try await rig.schedule(after: .milliseconds(100))
        #expect(request?.deadline.offset == .milliseconds(100))
        #expect(request?.tolerance == WakeLeeway.defaultAlignment)
    }

    @Test func aSubSecondDeadlineAsksTheDefaultAlignmentWithNoEnergySource() async throws {
        let rig = Rig()
        let request = try await rig.schedule(after: .milliseconds(450))
        #expect(request?.tolerance == .milliseconds(8))
    }

    @Test func energySaverWidensTheSubSecondToleranceAtTheNextSchedule() async throws {
        let energy = EnergyPolicySource()
        let rig = Rig(energy: energy)
        let normal = try await rig.schedule(after: .milliseconds(100))
        #expect(normal?.tolerance == WakeLeeway.defaultAlignment)

        energy.update(EnergyPolicy(saverReason: .setting))
        let saver = try await rig.schedule(after: .milliseconds(100))
        #expect(saver?.tolerance == WakeLeeway.saverAlignment)
        let precise = Rig(policy: .precise, energy: energy)
        let exact = try await precise.schedule(after: .milliseconds(20))
        #expect(exact?.tolerance == .zero)
    }

    @Test func preferEarlySleepsItsLeewayShortOfTheDeadline() async throws {
        let rig = Rig(policy: .flexiblePreferEarly)
        let request = try await rig.schedule(after: .milliseconds(450))
        #expect(request?.deadline.offset == .milliseconds(442))
        #expect(request?.tolerance == .milliseconds(8))
    }

    @Test func anExplicitToleranceReplacesTheFlexibleLeeway() async throws {
        let rig = Rig()
        let request = try await rig.schedule(after: .seconds(5), tolerance: .zero)
        #expect(request?.deadline.offset == .seconds(5))
        #expect(request?.tolerance == .zero)
    }

    /// `.flexiblePreferEarly` is never late, whoever sets the leeway: an explicit tolerance moves the
    /// sleep that much short of the deadline, as the policy's own leeway does.
    @Test func preferEarlyWithAnExplicitToleranceAsksTheDeadlineMinusTheTolerance() async throws {
        let rig = Rig(policy: .flexiblePreferEarly)
        let request = try await rig.schedule(after: .seconds(1), tolerance: .milliseconds(50))
        #expect(request?.deadline.offset == .milliseconds(950))
        #expect(request?.tolerance == .milliseconds(50))
    }

    @Test func preferEarlyWithAToleranceLongerThanTheDelayAsksNow() async throws {
        let rig = Rig(policy: .flexiblePreferEarly)
        let request = try await rig.schedule(after: .milliseconds(20), tolerance: .milliseconds(50))
        #expect(request?.deadline.offset == .zero)
        #expect(request?.tolerance == .milliseconds(50))
    }

    /// A precise deadline below 36 ms stays exact; an explicit tolerance does not make it flexible.
    @Test func aPreciseDeadlineIgnoresAnExplicitTolerance() async throws {
        let rig = Rig(policy: .precise)
        let request = try await rig.schedule(after: .milliseconds(20), tolerance: .milliseconds(10))
        #expect(request?.deadline.offset == .milliseconds(20))
        #expect(request?.tolerance == .zero)
    }

    /// The tolerance is what the timer asks the OS; the manual clock still fires at the deadline.
    @Test func theManualClockFiresAtTheDeadlineWhateverTheTolerance() async throws {
        let rig = Rig()
        _ = try await rig.schedule(after: .seconds(5))
        rig.clock.advance(by: .seconds(5) - .nanoseconds(1))
        #expect(rig.clock.sleeperCount == 1)
        #expect(rig.timer.isScheduled)
        rig.clock.advance(by: .nanoseconds(1))
        #expect(await rig.nextFire() == .seconds(5))
        #expect(!rig.timer.isScheduled)
    }

    /// A reset cancels the old sleep and asks the new deadline's tolerance; the old deadline never fires.
    @Test func aResetAsksTheNewDeadlinesTolerance() async throws {
        let rig = Rig()
        _ = try await rig.schedule(after: .seconds(5))
        rig.clock.advance(by: .seconds(1))
        let reset = try await rig.schedule(after: .milliseconds(200))
        #expect(reset?.deadline.offset == .milliseconds(1_200))
        #expect(reset?.tolerance == .milliseconds(8))
        #expect(rig.clock.sleeperCount == 1)
        rig.clock.advance(by: .milliseconds(200))
        #expect(await rig.nextFire() == .milliseconds(1_200))
        #expect(rig.fireCount == 1)

        // Past the old 5 s deadline, then one more deadline: the next fire is that one, and the
        // ledger holds exactly two fires, so the old deadline did not fire in between.
        rig.clock.advance(by: .seconds(10))
        _ = try await rig.schedule(after: .milliseconds(100))
        rig.clock.advance(by: .milliseconds(100))
        #expect(await rig.nextFire() == .milliseconds(11_300))
        #expect(rig.fireCount == 2)
    }
}
