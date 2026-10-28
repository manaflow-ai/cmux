import CmuxNextCompat
@testable import CmuxNextWakeups
import Dispatch
import Testing

/// Lane queue-wait and run-time histograms (plans/cmux-next/chrome-parity/p02-threads.md, task 123): log2 buckets
/// with 1 and 2 ms as edges, percentiles inside them, an upper-edge maximum, three clock reads per item (its run
/// report included), and a read-and-reset that loses no item.
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

    @Test func aResettingReadReturnsTheCountsAndZeroesThem() {
        let stats = LaneStats()
        for priority in WorkPriority.allCases { stats.record(priority, waitNanos: 5_000, runNanos: 7_000) }
        let taken = stats.snapshot(lane: .cpu, resetting: true)
        #expect(taken.allSatisfy { $0.wait.count == 1 && $0.wait.sumNanos == 5_000 && $0.run.sumNanos == 7_000 })
        #expect(stats.snapshot(lane: .cpu).allSatisfy { $0.wait == $0.run && $0.wait.count == 0 && $0.wait.sumNanos == 0 })
    }

    /// What one thread collects while others record.
    final class Collected: Sendable {
        let times = Mutex([LaneTimes]())
    }

    static let emptyHistogram = LaneHistogram(counts: Array(repeating: 0, count: LaneHistogram.bucketCount), sumNanos: 0)

    /// Writers record while a reader takes resetting reads: the reads plus a last one hold every item and every
    /// nanosecond exactly once (each counter is taken with one exchange, so nothing falls between read and reset).
    @Test func resettingReadsDuringRecordsLoseNoItem() {
        let stats = LaneStats()
        let reads = Collected()
        let writers = 4, perWriter = 50_000
        DispatchQueue.concurrentPerform(iterations: writers + 1) { index in
            guard index < writers else {
                for _ in 0..<500 {
                    let taken = stats.snapshot(lane: .cpu, resetting: true)
                    reads.times.withLock { $0 += taken }
                }
                return
            }
            for item in 0..<perWriter {
                stats.record(.userVisible, waitNanos: UInt64(item % 7) * Self.millisecond, runNanos: 2_000)
            }
        }
        let all = reads.times.withLock { $0 } + stats.snapshot(lane: .cpu, resetting: true)
        let visible = all.filter { $0.priority == .userVisible }
        let wait = visible.map(\.wait).reduce(Self.emptyHistogram) { $0.merged(with: $1) }
        let run = visible.map(\.run).reduce(Self.emptyHistogram) { $0.merged(with: $1) }
        let items = UInt64(writers * perWriter)
        let waitSum = UInt64(writers) * (0..<UInt64(perWriter)).reduce(0) { $0 + ($1 % 7) * Self.millisecond }
        #expect(wait.count == items)
        #expect(wait.sumNanos == waitSum)
        #expect(run.count == items)
        #expect(run.sumNanos == items * 2_000)
        #expect(all.filter { $0.priority != .userVisible }.allSatisfy { $0.wait.count == 0 && $0.run.count == 0 })
        #expect(stats.snapshot(lane: .cpu).allSatisfy { $0.wait.count == 0 && $0.run.count == 0 })
    }

    /// Through the lanes: each item costs three clock reads (submit, start, end), and its run time counts at the
    /// level it ran. The tests here ask for a serial files lane (``FilesLaneWidths/serial``, one item per level;
    /// the app's lane runs several), so a later item at the same level runs after the earlier ones recorded.
    @Test func eachLaneItemReadsTheClockThreeTimesAndCountsItsRun() async throws {
        let clock = ManualNanos()
        let work = BackgroundWork(cpuWidth: 1, filesWidths: .serial, label: "test.lane-stats.run", uptimeNanos: { clock.read() })
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
        let work = BackgroundWork(cpuWidth: 1, filesWidths: .serial, label: "test.lane-stats.wait", uptimeNanos: { clock.read() })
        work.beginBestEffortFence()
        work.post(.bestEffort, mayBlock: .files) { clock.advance(milliseconds: 50) }
        work.post(.bestEffort, mayBlock: .files) {}
        work.endBestEffortFence()
        // Posted (never boosted) at the same level, so it runs on the same slot after both recorded; it reads (and
        // resets) before it records itself.
        let (times, after) = await withCheckedContinuation { (continuation: CheckedContinuation<([LaneTimes], [LaneTimes]), Never>) in
            work.post(.bestEffort, mayBlock: .files) {
                continuation.resume(returning: (work.laneTimes(resetting: true), work.laneTimes()))
            }
        }
        let wait = try #require(Self.times(times, .files, .bestEffort)).wait
        #expect(wait.count == 2)
        #expect(wait.sumNanos == 50 * Self.millisecond)
        #expect(wait.maxNanos >= 50 * Self.millisecond)
        #expect(after.allSatisfy { $0.wait.count == 0 && $0.run.count == 0 })
    }

    /// `onRan` and the block-shutdown check get the stamps the lane took for its stats: an item that reports its
    /// run, block-shutdown or not, still reads the clock three times, and its report spans its body.
    @Test func aReportedItemReadsTheClockThreeTimes() async throws {
        let clock = ManualNanos()
        let reported = Collected()
        let onRan: @Sendable (BlockingLane, WorkPriority, UInt64, UInt64) -> Void = { lane, priority, start, end in
            let run = LaneHistogram(counts: [], sumNanos: end - start)
            reported.times.withLock { $0.append(LaneTimes(lane: lane, priority: priority, wait: run, run: run)) }
        }
        let work = BackgroundWork(cpuWidth: 1, filesWidths: .serial, label: "test.lane-stats.reported", onRan: onRan,
                                  uptimeNanos: { clock.read() })
        for index in 0..<10 {
            let shutdown: ShutdownBehavior = index.isMultiple(of: 2) ? .blockShutdown : .skipOnShutdown
            try await work.run(.userBlocking, mayBlock: .files, shutdown: shutdown) { clock.advance(milliseconds: 1) }
        }
        // Read before this item reports itself.
        let (reads, runs) = try await work.run(.userBlocking, mayBlock: .files) { (clock.reads, reported.times.withLock { $0 }) }
        // 10 items of three reads, then this one's submit and start.
        #expect(reads == 10 * 3 + 2)
        #expect(runs.count == 10)
        #expect(runs.allSatisfy { $0.lane == .files && $0.priority == .userBlocking && $0.run.sumNanos == Self.millisecond })
    }

    /// The user-blocking queue-wait p99 a hang report carries: a user-blocking item held 3 ms behind another shows
    /// a p99 between 2 and 4 ms, and a resetting read takes it back to 0.
    @Test func aSlowUserBlockingWaitShowsInTheP99() async throws {
        let clock = ManualNanos()
        let work = BackgroundWork(cpuWidth: 1, filesWidths: .serial, label: "test.lane-stats.p99",
                                  uptimeNanos: { clock.read() })
        let gate = DispatchSemaphore(value: 0)
        // The first holds the files lane's user-blocking slot until the second is queued behind it.
        work.post(.userBlocking, mayBlock: .files) {
            gate.wait()
            clock.advance(milliseconds: 3)
        }
        work.post(.userBlocking, mayBlock: .files) {}
        gate.signal()
        // Posted at the same level, so it runs on the same slot after both recorded, and reads before it records.
        let (p99, taken, after) = await withCheckedContinuation { (continuation: CheckedContinuation<(UInt64, UInt64, UInt64), Never>) in
            work.post(.userBlocking, mayBlock: .files) {
                continuation.resume(returning: (work.userBlockingQueueWaitP99Nanos,
                                                BackgroundWork.userBlockingQueueWaitP99Nanos(in: work.laneTimes(resetting: true)),
                                                work.userBlockingQueueWaitP99Nanos))
            }
        }
        #expect((2 * Self.millisecond...4 * Self.millisecond).contains(p99), "\(p99)")
        #expect(taken == p99)
        #expect(after == 0)
    }
}
