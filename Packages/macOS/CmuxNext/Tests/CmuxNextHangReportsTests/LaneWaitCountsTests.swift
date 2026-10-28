import CmuxNextCompat
@testable import CmuxNextHangReports
import CmuxNextWakeups
import Dispatch
import Foundation
import Testing

/// The background lanes' user-blocking queue-wait p99 in a hang report's coarse counts: a bucket
/// label, sent in schema 3 only, absent from schema 2 and from reports written before it.
struct LaneWaitCountsTests {
    /// A clock that moves only when a lane body moves it.
    final class ManualNanos: Sendable {
        private let now = Mutex(UInt64(0))

        func read() -> UInt64 { now.withLock { $0 } }
        func advance(milliseconds: UInt64) { now.withLock { $0 += milliseconds * 1_000_000 } }
    }

    @Test func waitBucketsAreLog2Milliseconds() {
        #expect(CoarseCounts.waitBucket(nanos: 0) == "0-1")
        #expect(CoarseCounts.waitBucket(nanos: 999_999) == "0-1")
        #expect(CoarseCounts.waitBucket(nanos: 1_000_000) == "1-2")
        #expect(CoarseCounts.waitBucket(nanos: 3_999_999) == "2-4")
        #expect(CoarseCounts.waitBucket(nanos: 4_000_000) == "4-8")
        #expect(CoarseCounts.waitBucket(nanos: 63_000_000) == "32-64")
        #expect(CoarseCounts.waitBucket(nanos: UInt64.max) == "64+")
        #expect((0..<200).map { CoarseCounts.waitBucket(nanos: UInt64($0) * 1_000_000) }.allSatisfy { CoarseCounts.waitLabels.contains($0) })
    }

    /// A user-blocking item held 3 ms behind another: the counts the app fills (`WatchdogReporting.counts`) carry
    /// the p99's label in a schema-3 report, and a schema-2 report leaves the key out.
    @Test func aReportBuiltAfterASlowUserBlockingWaitCarriesIt() async throws {
        let clock = ManualNanos()
        let work = BackgroundWork(cpuWidth: 1, label: "test.hang-report.lane-wait", uptimeNanos: { clock.read() })
        let gate = DispatchSemaphore(value: 0)
        work.post(.userBlocking, mayBlock: .files) {
            gate.wait()
            clock.advance(milliseconds: 3)
        }
        work.post(.userBlocking, mayBlock: .files) {}
        gate.signal()
        // Same level and slot: it runs after both recorded, and reads before it records itself.
        let p99 = await withCheckedContinuation { (continuation: CheckedContinuation<UInt64, Never>) in
            work.post(.userBlocking, mayBlock: .files) { continuation.resume(returning: work.userBlockingQueueWaitP99Nanos) }
        }
        var context = HangReportFixtures.context()
        context.counts = CoarseCounts(windows: 1, workspaces: 24, panes: 12, tabs: 72, userBlockingWaitP99Nanos: p99)
        let stall = StallAggregate()

        // Waits of 0 and 3 ms: the p99's rank is the 3 ms item, interpolated to the top of its 2-4 ms bucket.
        #expect(p99 == 4_000_000)
        let v3 = HangReportFixtures.builder(wireSchema: .v3).build(context: context, watchdog: stall, metricKit: [])
        #expect(v3.counts.userBlockingWaitP99Ms == "4-8")
        let v3JSON = String(decoding: try HangReport.encoder.encode(v3), as: UTF8.self)
        #expect(v3JSON.contains(#""userBlockingWaitP99Ms":"4-8""#), "\(v3JSON)")

        let v2 = HangReportFixtures.builder(wireSchema: .v2).build(context: context, watchdog: stall, metricKit: [])
        #expect(v2.counts.userBlockingWaitP99Ms == nil)
        #expect(!String(decoding: try HangReport.encoder.encode(v2), as: UTF8.self).contains("userBlockingWaitP99Ms"))
    }

    @Test func aLabelOutsideTheClosedSetIsDropped() {
        var context = HangReportFixtures.context()
        context.counts.userBlockingWaitP99Ms = "/Users/alice"
        let report = HangReportFixtures.builder(wireSchema: .v3).build(context: context, watchdog: StallAggregate(), metricKit: [])
        #expect(report.counts.userBlockingWaitP99Ms == nil)
    }

    @Test func aReportWrittenBeforeTheFieldStillDecodes() throws {
        let report = try JSONDecoder().decode(HangReport.self, from: Data(HangReportWireFormatTests.golden.utf8))
        #expect(report.counts.userBlockingWaitP99Ms == nil)
        #expect(report.counts.windows == "1")
    }
}
