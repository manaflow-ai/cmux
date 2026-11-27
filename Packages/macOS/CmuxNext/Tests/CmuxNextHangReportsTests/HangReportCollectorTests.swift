@testable import CmuxNextHangReports
import CmuxNextCompat
import Foundation
import Testing

/// The watchdog sink counts every stall, keeps the stacks of the longest, does nothing while off,
/// and the aggregate survives a relaunch.
struct HangReportCollectorTests {
    private func collector(resolved: @escaping @Sendable ([UInt]) -> [HangReportFrame] = { _ in [HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 1)] })
        -> HangReportCollector {
        HangReportCollector(resolve: resolved, schedule: { $0() })
    }

    private static func nanos(_ ms: Int) -> UInt64 { UInt64(ms) * 1_000_000 }

    @Test func offRecordsNothing() {
        let collector = collector()
        collector.noteStall(durationNanos: Self.nanos(400), cpuNanos: 0, addresses: [1])
        collector.noteHang(durationNanos: Self.nanos(2_000), addresses: [1])
        #expect(collector.drain().isEmpty)
    }

    @Test func countsEveryStallAndKeepsTheEightLongestStacks() {
        let collector = collector()
        collector.setEnabled(true)
        for ms in [60, 120, 260, 300, 310, 320, 330, 340, 350, 360, 370, 1_500, 2_500] {
            collector.noteStall(durationNanos: Self.nanos(ms), cpuNanos: Self.nanos(ms / 2), addresses: [1, 2])
        }
        let aggregate = collector.drain()
        #expect(aggregate.histogram == [
            HistogramBucket(lowMs: 50, highMs: 100, count: 1), HistogramBucket(lowMs: 100, highMs: 250, count: 1),
            HistogramBucket(lowMs: 250, highMs: 500, count: 9), HistogramBucket(lowMs: 1_000, highMs: 2_000, count: 1),
            HistogramBucket(lowMs: 2_000, highMs: 5_000, count: 1),
        ])
        // A hang-length stall is only counted; its stack comes from noteHang.
        #expect(aggregate.stalls.map(\.durationMs) == [1_500, 370, 360, 350, 340, 330, 320, 310])
        #expect(aggregate.stalls.allSatisfy { $0.kind == .stall && $0.source == .watchdog && !$0.frames.isEmpty })
        #expect(aggregate.stalls.first?.cpuMs == 750)
        #expect(collector.drain().isEmpty)
    }

    @Test func hangsKeepTheirStackSampledWhileTheyRan() {
        let collector = collector()
        collector.setEnabled(true)
        collector.noteHang(durationNanos: Self.nanos(2_000), addresses: [1])
        #expect(collector.snapshot().hangs.map(\.kind) == [.hang])
    }

    @Test func turningOffDropsWhatWasRecorded() {
        let collector = collector()
        collector.setEnabled(true)
        collector.noteStall(durationNanos: Self.nanos(400), cpuNanos: 0, addresses: [1])
        collector.setEnabled(false)
        collector.setEnabled(true)
        #expect(collector.drain().isEmpty)
    }

    @Test func anAggregateSurvivesEncodingAndMerges() throws {
        var aggregate = StallAggregate()
        aggregate.count(durationMs: 70)
        aggregate.keep(HangSample(source: .watchdog, kind: .stall, durationMs: 400, frames: [.other]))
        let decoded = try JSONDecoder().decode(StallAggregate.self, from: JSONEncoder().encode(aggregate))
        #expect(decoded == aggregate)
        let collector = collector()
        collector.setEnabled(true)
        collector.noteStall(durationNanos: Self.nanos(80), cpuNanos: 0, addresses: [])
        collector.merge(decoded)
        let merged = collector.drain()
        #expect(merged.histogram == [HistogramBucket(lowMs: 50, highMs: 100, count: 2)])
        #expect(merged.stalls.count == 1)
    }

    /// hq#18810: the main thread hung 2.0 s starting a resolution task at a stall's end, one task per
    /// sampled stall. A burst of sampled stalls now starts one job (before: 9 for these 9 stalls).
    @Test func aBurstOfStallsStartsOneResolutionJob() {
        let jobs = Mutex<[@Sendable () -> Void]>([])
        let collector = HangReportCollector(resolve: { _ in [.other] }, schedule: { job in jobs.withLock { $0.append(job) } })
        collector.setEnabled(true)
        for ms in [300, 310, 320, 330, 340, 350, 360, 370, 380] {
            collector.noteStall(durationNanos: Self.nanos(ms), cpuNanos: 0, addresses: [1])
        }
        #expect(jobs.withLock { $0.count } == 1)
        jobs.withLock { $0.removeFirst() }()
        #expect(collector.snapshot().stalls.count == 8, "the one job resolves every waiting stall")
        // It schedules one follow-up, which finds nothing and ends the run.
        #expect(jobs.withLock { $0.count } == 1)
        jobs.withLock { $0.removeFirst() }()
        #expect(jobs.withLock { $0.isEmpty })
        collector.noteStall(durationNanos: Self.nanos(400), cpuNanos: 0, addresses: [1])
        #expect(jobs.withLock { $0.count } == 1, "a stall after the job ended starts the next")
    }

    /// hq#18810: the default job starts from a dispatch source made at init (the main thread allocates
    /// no task at a stall's end) and still resolves every waiting stall; a snapshot is a copy of its own.
    @Test func theDefaultJobResolvesOffTheMainThread() async throws {
        let collector = HangReportCollector(resolve: { _ in
            #expect(!Thread.isMainThread, "symbol resolution must stay off the watchdog's main thread")
            return [.other]
        })
        collector.setEnabled(true)
        for ms in [300, 400, 500] {
            collector.noteStall(durationNanos: Self.nanos(ms), cpuNanos: 0, addresses: [1])
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while collector.snapshot().stalls.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = collector.snapshot()
        #expect(snapshot.stalls.map(\.durationMs) == [500, 400, 300])
        #expect(snapshot.stalls.allSatisfy { $0.frames == [.other] })
        collector.noteStall(durationNanos: Self.nanos(100), cpuNanos: 0, addresses: [])
        #expect(collector.snapshot().counts != snapshot.counts, "the snapshot kept its own counts")
        #expect(collector.snapshot().stalls == snapshot.stalls)
    }

    /// A slow resolver must not hold the collector lock or stop a burst of main-thread reports.
    @Test func aBlockedDefaultResolverDoesNotBlockMainThreadReports() async throws {
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let collector = HangReportCollector(resolve: { _ in
            #expect(!Thread.isMainThread)
            if entered.withLock({ entered in
                let first = !entered
                entered = true
                return first
            }) {
                #expect(release.wait(timeout: .now() + 10) == .success)
            }
            return [.other]
        })
        defer { release.signal() }
        collector.setEnabled(true)
        await MainActor.run {
            #expect(Thread.isMainThread)
            collector.noteStall(durationNanos: Self.nanos(500), cpuNanos: 0, addresses: [1])
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(entered.withLock { $0 }, "default resolver started")
        let elapsed = await MainActor.run {
            let start = ContinuousClock.now
            for _ in 0..<6_000 {
                collector.noteStall(durationNanos: Self.nanos(500), cpuNanos: 0, addresses: [1])
            }
            return ContinuousClock.now - start
        }
        print("BENCH blocked-resolver main-thread n=6000 elapsed=\(elapsed)")
        #expect(elapsed < .seconds(2), "6,000 reports must not wait for the blocked resolver")
    }

    @Test func coarseCountsAreBuckets() {
        #expect([0, 1, 2, 5, 6, 10, 11, 30, 31, 100, 101, 5_000].map(CoarseCounts.bucket)
            == ["0", "1", "2-5", "2-5", "6-10", "6-10", "11-30", "11-30", "31-100", "31-100", "101+", "101+"])
    }
}
