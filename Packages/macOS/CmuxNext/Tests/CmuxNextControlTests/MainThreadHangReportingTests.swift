@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// `debug.hangs` reads the watchdog only through ``MainThreadHangReporting`` (p15-oracle-136), so Control
/// answers it with no watchdog type of its own: these drive the method with a hand-made reporter.
@Suite struct MainThreadHangReportingTests {
    @Test func debugHangsReportsWhatTheReporterHolds() async throws {
        let reporter = FakeHangReporter()
        reporter.log.append(startUptimeNanos: 1_000, duration: .milliseconds(80), addresses: [])
        reporter.threadJanks.append(startUptimeNanos: 2_000, duration: .milliseconds(3), addresses: [], kind: .jank)
        let router = Self.router(reporter)

        let reply = try await router.handle(ControlRequest(id: "1", method: "debug.hangs", params: [:])).get()
        #expect(reply["installed"] == true)
        #expect(reply["threshold_ms"] == 25)
        #expect(reply["count"] == 1)
        #expect(reply["max_ms"] == 80)
        #expect(reply["records"]?.arrayValue?.count == 1)
        #expect(reply["thread_jank_count"] == 1)
        #expect(reply["long_frames"] == 3)
        #expect(reply["frames_over_8_3ms"] == 5)
        #expect(reply["count100"] == 2)
        #expect(reply["count250"] == 1)
        #expect(reply["main_wakes"] == 42)
        #expect(reply["turn_histogram"] == FakeHangReporter.histogram)
        #expect(reporter.resets.load(ordering: .relaxed) == 0)
    }

    @Test func clearResetsEveryCounterAndLog() async throws {
        let reporter = FakeHangReporter()
        reporter.log.append(startUptimeNanos: 1_000, duration: .milliseconds(80), addresses: [])
        reporter.overBudget.append(startUptimeNanos: 1_000, duration: .milliseconds(9), addresses: [], kind: .overBudget)
        let router = Self.router(reporter)

        let reply = try await router.handle(ControlRequest(id: "1", method: "debug.hangs", params: ["clear": true])).get()
        // The reply is read before the clear; the next read sees it.
        #expect(reply["count"] == 1)
        #expect(reporter.resets.load(ordering: .relaxed) == 3)
        #expect(reporter.log.summary.count == 0)
        #expect(reporter.overBudget.summary.count == 0)
    }

    @Test func noReporterAnswersNotInstalled() async throws {
        let router = Self.router(nil)
        let reply = try await router.handle(ControlRequest(id: "1", method: "debug.hangs", params: [:])).get()
        #expect(reply["installed"] == false)
        #expect(reply["count"] == 0)
    }

    private static func router(_ reporter: (any MainThreadHangReporting)?) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: CountingExecutor(), configuration: .init(allowsDebugMethods: true))
        router.snapshots.publish { $0 = .sample() }
        router.attach(watchdog: reporter)
        return router
    }
}

/// A reporter with fixed counters that counts its resets (three per `clear`: frames, stalls, histograms).
private final class FakeHangReporter: MainThreadHangReporting {
    static let histogram: JSONValue = ["edges_us": [50], "main_turn": ["count": 7], "input_queueing": ["count": 2]]

    let log = HangLog(capacity: 8), overBudget = HangLog(capacity: 8), taskHangs = HangLog(capacity: 8)
    let threadHangs = HangLog(capacity: 8), threadJanks = HangLog(capacity: 8)
    let resets = Atomic<Int>(0)

    var isRunning: Bool { true }
    var stallThreshold: Duration { .milliseconds(25) }
    var longFrameStats: (count: Int, max: Duration) { (3, .milliseconds(40)) }
    var gapStats: (over120HzFrame: Int, max: Duration) { (5, .milliseconds(80)) }
    var stallCounts: StallCounts { StallCounts(count100: 2, count250: 1) }
    var mainRunLoopWakes: UInt64 { 42 }
    var turnHistogramJSON: JSONValue { Self.histogram }
    func resetLongFrames() { resets.add(1, ordering: .relaxed) }
    func resetStallCounts() { resets.add(1, ordering: .relaxed) }
    func resetTurnHistograms() { resets.add(1, ordering: .relaxed) }
    func endHangAssertions() {}
}
