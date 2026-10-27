import Testing
@testable import CmuxNextWakeups

/// A clock that stays at zero, records each sleep's delay and tolerance, and
/// returns at once.
private final class RecordingClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    struct Sleep: Equatable, Sendable {
        var delay: Duration
        var tolerance: Duration?
    }

    actor Log {
        private(set) var sleeps: [Sleep] = []
        func append(_ sleep: Sleep) { sleeps.append(sleep) }
    }

    let log = Log()
    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await log.append(Sleep(delay: deadline.offset, tolerance: tolerance))
    }
}

@Suite struct BackoffTests {
    @Test func growsExponentiallyAndCaps() {
        var backoff = Backoff(initial: .milliseconds(100), maximum: .seconds(1), jitter: 0, random: { 0.5 })
        let delays = (0..<6).map { _ in backoff.next() }
        #expect(delays == [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800), .seconds(1), .seconds(1)])
        backoff.reset()
        #expect(backoff.next() == .milliseconds(100))
    }

    @Test func jitterStaysWithinItsFraction() {
        var low = Backoff(initial: .seconds(1), maximum: .seconds(10), jitter: 0.2, random: { 0 })
        var high = Backoff(initial: .seconds(1), maximum: .seconds(10), jitter: 0.2, random: { 0.999_999 })
        #expect(abs(low.next().inSeconds - 0.8) < 0.001)
        #expect(abs(high.next().inSeconds - 1.2) < 0.001)
    }

    /// Settings outside the documented ranges used to trap in the initializer.
    @Test func outOfRangeSettingsAreCorrectedInsteadOfTrapping() {
        var backoff = Backoff(initial: .zero, maximum: .zero, multiplier: 0.5, jitter: 2, random: { 0.5 })
        #expect(backoff.initial == .milliseconds(100))
        #expect(backoff.maximum == .milliseconds(100))
        #expect(backoff.multiplier == 1)
        #expect(backoff.jitter == 1)
        #expect(backoff.next() == .milliseconds(100))
        let nanJitter = Backoff(jitter: .nan)
        #expect(nanJitter.jitter == 0)
    }

    /// A retry table walks its steps, repeats the last, and jitters each step as the geometric
    /// schedule does; reset starts it over.
    @Test func aStepTableWalksItsStepsThenRepeatsTheLast() {
        var backoff = Backoff(steps: [.seconds(5), .seconds(15), .seconds(60)], random: { 0.5 })
        #expect((0..<5).map { _ in backoff.next() } == [.seconds(5), .seconds(15), .seconds(60), .seconds(60), .seconds(60)])
        #expect(backoff.initial == .seconds(5))
        #expect(backoff.maximum == .seconds(60))
        backoff.reset()
        #expect(backoff.next() == .seconds(5))
        var low = Backoff(steps: [.seconds(5)], jitter: 0.2, random: { 0 })
        var high = Backoff(steps: [.seconds(5)], jitter: 0.2, random: { 0.999_999 })
        #expect(abs(low.next().inSeconds - 4) < 0.001)
        #expect(abs(high.next().inSeconds - 6) < 0.001)
        var empty = Backoff(steps: [], random: { 0 })
        #expect(empty.next() == .zero)
        var negative = Backoff(steps: [.seconds(-1)], random: { 0 })
        #expect(negative.next() == .zero)
    }

    @Test func toleranceIsTenPercentOfTheStepWithAnEightMillisecondFloor() {
        #expect(Backoff.tolerance(for: .milliseconds(50)) == .milliseconds(8))
        #expect(Backoff.tolerance(for: .milliseconds(80)) == .milliseconds(8))
        #expect(Backoff.tolerance(for: .milliseconds(500)) == .milliseconds(50))
        #expect(Backoff.tolerance(for: .seconds(2)) == .milliseconds(200))
        #expect(Backoff.tolerance(for: .seconds(30)) == .seconds(3))
    }

    /// Each wait asks the clock for slack, so the kernel can coalesce the retry
    /// with other wakes; the step stays the delay and the ledger reason stays `backoff`.
    @Test func waitSleepsWithToleranceAndRecordsBackoff() async throws {
        let clock = RecordingClock()
        let ledger = WakeupLedger()
        var backoff = Backoff(initial: .milliseconds(50), maximum: .seconds(2), multiplier: 40, jitter: 0, random: { 0.5 })
        try await backoff.wait(owner: "test.retry", clock: clock, ledger: ledger)
        try await backoff.wait(owner: "test.retry", clock: clock, ledger: ledger)
        #expect(await clock.log.sleeps == [
            RecordingClock.Sleep(delay: .milliseconds(50), tolerance: .milliseconds(8)),
            RecordingClock.Sleep(delay: .seconds(2), tolerance: .milliseconds(200)),
        ])
        let entries = ledger.snapshot()
        #expect(entries.map(\.owner) == ["test.retry"])
        #expect(entries.map(\.reason) == ["backoff"])
        #expect(entries.first?.count == 2)
    }

    /// Jitter stays: the tolerance follows the jittered step, not the base.
    @Test func jitteredStepSetsTheTolerance() async throws {
        let clock = RecordingClock()
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(10), jitter: 0.2, random: { 0 })
        try await backoff.wait(owner: "test.retry", clock: clock, ledger: WakeupLedger())
        let sleep = try #require(await clock.log.sleeps.first)
        #expect(abs(sleep.delay.inSeconds - 0.8) < 0.001)
        #expect(abs((sleep.tolerance ?? .zero).inSeconds - 0.08) < 0.001)
    }
}
