import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The daemon heartbeat asks nothing while the Mac or its displays sleep, counts no
/// miss for an ask the sleep cut off, and asks once soon after a wake finds the network.
@Suite(.timeLimit(.minutes(1)))
struct ConnectionHeartbeatSleepTests {
    /// The asks a probe made and the closes it asked for.
    final class Probe: Sendable {
        private let counts = Mutex((asks: 0, closes: 0))
        let asked: AsyncStream<Void>
        private let asking: AsyncStream<Void>.Continuation
        /// What each ask answers; nil holds the ask until `release` resolves it.
        private let answer: FirstOutcome<Bool>?

        init(holding: Bool = false) {
            (asked, asking) = AsyncStream.makeStream(of: Void.self)
            answer = holding ? FirstOutcome() : nil
        }

        var asks: Int { counts.withLock { $0.asks } }
        var closes: Int { counts.withLock { $0.closes } }

        func release(_ answered: Bool) { answer?.resolve(answered) }

        func probe(interval: Duration = .seconds(15), misses: Int = 1) -> ConnectionHeartbeat.Probe {
            ConnectionHeartbeat.Probe(ask: { [self] _ in
                counts.withLock { $0.asks += 1 }
                asking.yield()
                return await answer?.value() ?? true
            }, close: { [self] in counts.withLock { $0.closes += 1 } }, interval: interval, misses: misses)
        }
    }

    @Test func willSleepSendsNoAsk() async throws {
        let clock = ManualClock()
        let energy = EnergyPolicySource()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        heartbeat.follow(KeepaliveGate(energy, random: { 0.5 }))
        let probe = Probe()
        heartbeat.start(probe.probe())
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(15))

        energy.update(EnergyPolicy(suspended: true))
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(3600))
        #expect(probe.asks == 0)

        // Asleep displays hold it the same way once the Mac is awake.
        energy.update(EnergyPolicy(screensAsleep: true))
        #expect(clock.sleeperCount == 0)
        heartbeat.stop()
    }

    @Test func aWakeThatFindsTheNetworkAsksOnceSoon() async throws {
        let clock = ManualClock()
        let energy = EnergyPolicySource()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        heartbeat.follow(KeepaliveGate(energy, random: { 0.5 }))
        let probe = Probe()
        heartbeat.start(probe.probe())
        try await clock.waitForSleeper()
        energy.update(EnergyPolicy(suspended: true))
        clock.advance(by: .seconds(600))

        energy.update(EnergyPolicy())
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(615))
        // The path is back: one ask after the wake's wait (1 s at half the 2 s jitter), not the interval.
        energy.update(EnergyPolicy(networkResumes: 1))
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(601))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        for await _ in probe.asked { break }
        // Then the interval again.
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline.offset == .seconds(616))
        #expect(probe.asks == 1)
        heartbeat.stop()
    }

    @Test func anAskTheSleepCutOffCountsNoMiss() async throws {
        let clock = ManualClock()
        let energy = EnergyPolicySource()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        heartbeat.follow(KeepaliveGate(energy))
        let probe = Probe(holding: true)
        heartbeat.start(probe.probe(misses: 1))
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(15))
        for await _ in probe.asked { break }

        energy.update(EnergyPolicy(suspended: true))
        // Its timeout ran through the sleep: unanswered, and still no close.
        probe.release(false)
        energy.update(EnergyPolicy())
        try await clock.waitForSleeper()
        #expect(probe.closes == 0)
        #expect(probe.asks == 1)
        heartbeat.stop()
    }

    @Test func withNoPolicyTheHeartbeatAsksOnItsInterval() async throws {
        let clock = ManualClock()
        let heartbeat = ConnectionHeartbeat(clock: clock)
        let probe = Probe()
        heartbeat.start(probe.probe())
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(15))
        for await _ in probe.asked { break }
        #expect(probe.asks == 1)
        heartbeat.stop()
    }
}
