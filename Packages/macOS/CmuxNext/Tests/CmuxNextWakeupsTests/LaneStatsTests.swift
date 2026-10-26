import CmuxNextCompat
@testable import CmuxNextWakeups
import Testing

/// Lane queue-wait and run-time histograms (plans/cmux-next/chrome-parity/p02-threads.md, task 123): log2 buckets
/// with 1 and 2 ms as edges, percentiles inside them, an upper-edge maximum, and three clock reads per item.
@Suite(.timeLimit(.minutes(1))) struct LaneStatsTests {
    /// A clock that moves only when a lane body moves it, and counts its reads.
    final class ManualNanos: Sendable {
        private let state = Mutex((now: UInt64(0), reads: 0))

        func read() -> UInt64 { state.withLock { $0.reads += 1; return $0.now } }
        func advance(milliseconds: UInt64) { state.withLock { $0.now += milliseconds * 1_000_000 } }
        var reads: Int { state.withLock { $0.reads } }
    }

    static let millisecond: UInt64 = 1_000_000

    /// The histogram of `lane` at `priority` in `times`.
    static func times(_ times: [LaneTimes], _ lane: BlockingLane, _ priority: WorkPriority) -> LaneTimes? {
        times.first { $0.lane == lane && $0.priority == priority }
    }

    @Test func millisecondsAndTheirDoublesAreBucketEdges() {
        #expect(LaneHistogram.bucket(forNanos: 0) == 0)
        #expect(LaneHistogram.bucket(forNanos: 900) == 0)
        let oneMs = LaneHistogram.bucket(forNanos: Self.millisecond)
        #expect(LaneHistogram.lowerEdgeNanos(oneMs) == Self.millisecond)
        #expect(LaneHistogram.upperEdgeNanos(oneMs) == 2 * Self.millisecond)
        #expect(LaneHistogram.bucket(forNanos: 2 * Self.millisecond - 1) == oneMs)
        #expect(LaneHistogram.bucket(forNanos: 2 * Self.millisecond) == oneMs + 1)
        #expect(LaneHistogram.bucket(forNanos: UInt64.max) == LaneHistogram.bucketCount - 1)
    }

    @Test func hundredOneMillisecondRunsHaveAMedianBetweenOneAndTwoMilliseconds() throws {
        let stats = LaneStats()
        for _ in 0..<100 { stats.record(.userBlocking, waitNanos: 0, runNanos: Self.millisecond) }
        let run = try #require(Self.times(stats.snapshot(lane: .files), .files, .userBlocking)).run
        #expect(run.count == 100)
        #expect(run.sumNanos == 100 * Self.millisecond)
        #expect((Self.millisecond...2 * Self.millisecond).contains(run.percentileNanos(0.5)), "\(run.percentileNanos(0.5))")
        #expect(run.maxNanos == 2 * Self.millisecond)
    }

    @Test func aFiftyMillisecondWaitShowsAMaximumOfAtLeastFiftyMilliseconds() throws {
        let stats = LaneStats()
        stats.record(.bestEffort, waitNanos: 50 * Self.millisecond, runNanos: 0)
        let times = stats.snapshot(lane: .system)
        let wait = try #require(Self.times(times, .system, .bestEffort)).wait
        #expect(wait.maxNanos >= 50 * Self.millisecond)
        #expect(wait.maxNanos < 100 * Self.millisecond)
        // The other priorities saw nothing.
        #expect(times.filter { $0.priority != .bestEffort }.allSatisfy { $0.wait.count == 0 && $0.run.count == 0 })
    }

    @Test func resetZeroesEveryCountAndSum() {
        let stats = LaneStats()
        for priority in WorkPriority.allCases { stats.record(priority, waitNanos: 5_000, runNanos: 7_000) }
        stats.reset()
        #expect(stats.snapshot(lane: .cpu).allSatisfy { $0.wait == $0.run && $0.wait.count == 0 && $0.wait.sumNanos == 0 })
    }

    /// Through the lanes: each item costs three clock reads (submit, start, end), and its run time counts at the
    /// level it ran. The files lane runs one item per level, so a later item at the same level runs after the
    /// earlier ones recorded.
    @Test func eachLaneItemReadsTheClockThreeTimesAndCountsItsRun() async throws {
        let clock = ManualNanos()
        let work = BackgroundWork(cpuWidth: 1, label: "test.lane-stats.run", uptimeNanos: { clock.read() })
        for _ in 0..<100 {
            try await work.run(.userBlocking, mayBlock: .files) { clock.advance(milliseconds: 1) }
        }
        let (times, reads) = try await work.run(.userBlocking, mayBlock: .files) { (work.laneTimes(), clock.reads) }
        // 100 items of three reads, then this one's submit and start.
        #expect(reads == 100 * 3 + 2)
        let files = try #require(Self.times(times, .files, .userBlocking))
        #expect(files.run.count == 100)
        #expect(files.run.sumNanos == 100 * Self.millisecond)
        #expect((Self.millisecond...2 * Self.millisecond).contains(files.run.percentileNanos(0.5)))
        #expect(times.filter { $0.lane != .files }.allSatisfy { $0.run.count == 0 })
        #expect(work.userBlockingQueueWaitP99Nanos < Self.millisecond)
    }

    /// An item held 50 ms behind another on its slot shows that wait. The fence queues both before either runs,
    /// so both are submitted at the same instant and the second starts when the first's body has moved the clock.
    @Test func anItemHeldFiftyMillisecondsShowsItsWait() async throws {
        let clock = ManualNanos()
        let work = BackgroundWork(cpuWidth: 1, label: "test.lane-stats.wait", uptimeNanos: { clock.read() })
        work.beginBestEffortFence()
        work.post(.bestEffort, mayBlock: .files) { clock.advance(milliseconds: 50) }
        work.post(.bestEffort, mayBlock: .files) {}
        work.endBestEffortFence()
        // Posted (never boosted) at the same level, so it runs on the same slot after both recorded.
        let times = await withCheckedContinuation { (continuation: CheckedContinuation<[LaneTimes], Never>) in
            work.post(.bestEffort, mayBlock: .files) { continuation.resume(returning: work.laneTimes()) }
        }
        let wait = try #require(Self.times(times, .files, .bestEffort)).wait
        #expect(wait.count == 2)
        #expect(wait.sumNanos == 50 * Self.millisecond)
        #expect(wait.maxNanos >= 50 * Self.millisecond)
        work.resetLaneTimes()
        #expect(work.laneTimes().allSatisfy { $0.wait.count == 0 && $0.run.count == 0 })
    }
}
