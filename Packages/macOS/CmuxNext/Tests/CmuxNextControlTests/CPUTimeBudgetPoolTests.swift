import CmuxNextWakeups
import Foundation
import Testing

/// The CPU-time budget of hidden nodes' main-thread work (plans/cmux-next/chrome-parity/
/// p06-scheduler.md, p06-scheduler-210): 10 ms/s refill, 100 ms cap, visible and exempt work free.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CPUTimeBudgetPoolTests {
    private static let ms: UInt64 = 1_000_000
    private static let second: UInt64 = 1_000_000_000

    @Test func twentyMillisecondsPerFireIsHeldToTenMillisecondsPerSecond() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        var runs: [Int] = []
        // A hidden repeating timer on 1 s-aligned wakes, 20 ms of work per fire, for 200 s.
        for wake in 0 ..< 200 {
            clock.now = clock.origin + UInt64(wake) * Self.second
            guard pool.mayRun(.hidden) else { continue }
            pool.run(.hidden) { clock.now += 20 * Self.ms }
            runs.append(wake)
        }
        // The full 100 ms balance pays for the first 10 fires; after that every second wake has budget.
        #expect(Array(runs.prefix(10)) == Array(0 ..< 10))
        #expect(runs.filter { $0 >= 100 }.count == 50, "steady state: 20 ms every 2 s is 10 ms/s")
        let charged = pool.stats.charged
        #expect(charged <= .milliseconds(100 + 10 * 200 + 20), "never more than the cap plus 10 ms/s plus one fire")
        #expect(charged >= .milliseconds(10 * 200 - 20))
        #expect(pool.stats.hiddenRuns == runs.count)
    }

    @Test func aNegativeBalanceWaitsForTheRefillToZero() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        pool.record(.hidden, ran: .milliseconds(120))
        #expect(pool.balance == .milliseconds(-20))
        #expect(!pool.mayRun(.hidden))
        #expect(pool.delayUntilAllowed(.hidden) == .seconds(2), "20 ms at 10 ms/s")
        clock.now += Self.second
        #expect(pool.delayUntilAllowed(.hidden) == .seconds(1))
        clock.now += Self.second
        #expect(pool.delayUntilAllowed(.hidden) == .zero)
        #expect(pool.mayRun(.hidden), "a zero balance runs (Blink: the next allowed time is now)")
    }

    @Test func theBalanceRefillsUpToTheCapOnly() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        #expect(pool.balance == .milliseconds(100), "a new pool starts full")
        pool.record(.hidden, ran: .milliseconds(60))
        clock.now += 3 * Self.second
        #expect(pool.balance == .milliseconds(70))
        clock.now += 3600 * Self.second
        #expect(pool.balance == .milliseconds(100), "an hour hidden and idle still allows only 100 ms at once")
    }

    @Test func oneLongTaskHoldsHiddenWorkBackForTheMaxDelayAtMost() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        pool.record(.hidden, ran: .seconds(600))
        #expect(pool.balance == .milliseconds(-600), "the floor is what refills in 60 s")
        #expect(pool.delayUntilAllowed(.hidden) == .seconds(60))
    }

    @Test func visibleWorkIsNeverChargedAndNeverWaits() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        for _ in 0 ..< 1000 {
            #expect(pool.mayRun(.visible))
            pool.run(.visible) { clock.now += 20 * Self.ms }
        }
        pool.record(.visible, ran: .seconds(5))
        #expect(pool.balance == .milliseconds(100))
        #expect(pool.stats == CPUTimeBudgetPool.Stats())
        #expect(pool.mayRun(.hidden), "visible work leaves the hidden budget untouched")
    }

    @Test func exemptWorkIsNeverDeferredOrCharged() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        pool.record(.hidden, ran: .milliseconds(300))
        #expect(!pool.mayRun(.hidden))
        let before = pool.balance
        for _ in 0 ..< 100 {
            #expect(pool.delayUntilAllowed(.exempt) == .zero, "media or a capture vote is never deferred")
            pool.run(.exempt) { clock.now += 20 * Self.ms }
        }
        // 2 s passed in the exempt runs: only the refill moved the balance.
        #expect(pool.balance == before + .milliseconds(20))
        #expect(pool.stats.hiddenRuns == 1)
    }

    @Test func theChargeFollowsTheNodeState() {
        #expect(CPUTimeBudgetPool.Charge(isVisible: true, mediaOrCapture: false) == .visible)
        #expect(CPUTimeBudgetPool.Charge(isVisible: true, mediaOrCapture: true) == .visible)
        #expect(CPUTimeBudgetPool.Charge(isVisible: false, mediaOrCapture: true) == .exempt)
        #expect(CPUTimeBudgetPool.Charge(isVisible: false, mediaOrCapture: false) == .hidden)
    }

    @Test func aRunThatThrowsIsStillCharged() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        #expect(throws: PoolProbeError.self) {
            try pool.run(.hidden) {
                clock.now += 30 * Self.ms
                throw PoolProbeError()
            }
        }
        #expect(pool.balance == .milliseconds(70))
    }
}

private struct PoolProbeError: Error {}

private final class PoolClock {
    let origin: UInt64 = 1_000_000_000
    var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
}
