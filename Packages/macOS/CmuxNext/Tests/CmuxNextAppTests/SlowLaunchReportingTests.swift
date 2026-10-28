@testable import CmuxNextApp
import CmuxNextHangReports
import CmuxNextLaunch
import Foundation
import Testing

/// The slow-launch ring's end in the app (p08-startup-111): only a Mac with the consent record on a sending build makes
/// the ring; a forced slow launch's ring becomes a report trace (kinds, overwritten records as dropped); and the trace
/// waits for the first on/off decision instead of being dropped by a collector that is not on yet.
@MainActor @Suite struct SlowLaunchReportingTests {
    private static let nightly = "com.cmuxterm.app.nightly"

    private static func defaults(consented: Bool) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "test.slow-launch.\(UUID().uuidString)"))
        if consented { defaults.set(Date(), forKey: HangReportsController.consentKey) }
        return defaults
    }

    @Test func onlyASendingBuildWithTheConsentRecordMakesTheRing() throws {
        let yes = try Self.defaults(consented: true), no = try Self.defaults(consented: false)
        #expect(HangReportsController.recordsSlowLaunch(bundleID: Self.nightly, isDebugBuild: false, defaults: yes, environment: [:]))
        #expect(!HangReportsController.recordsSlowLaunch(bundleID: Self.nightly, isDebugBuild: false, defaults: no, environment: [:]))
        // Release never sends; DEV only with the opt-in; a test process never.
        #expect(!HangReportsController.recordsSlowLaunch(bundleID: "com.cmuxterm.app", isDebugBuild: false, defaults: yes, environment: [:]))
        #expect(!HangReportsController.recordsSlowLaunch(bundleID: Self.nightly, isDebugBuild: true, defaults: yes, environment: [:]))
        #expect(HangReportsController.recordsSlowLaunch(bundleID: Self.nightly, isDebugBuild: true, defaults: yes,
                                                       environment: [HangReportsController.devOptInKey: "1"]))
        #expect(!HangReportsController.recordsSlowLaunch(bundleID: Self.nightly, isDebugBuild: false, defaults: yes,
                                                        environment: ["CMUX_TEST_PROCESS": "1"]))
    }

    /// A forced slow launch: a warm launch whose first frame came at 640 ms, past the 180 ms budget.
    @Test func aForcedSlowLaunchsRingBecomesTheReportsTrace() throws {
        let record = try #require(LaunchAggregate.Record(marks: [
            ("launch.temperature.warm", 90), ("first_window_frame_committed", 640), ("startup_complete.visiblePaneLoadedIdle", 2_000),
            ("startup_complete", 2_000),
        ]))
        #expect(HangReport.LaunchTrace.exceedsBudget(record))
        let ring = StartupTrace.SlowLaunchRing(processStartNanos: 0, bytes: 3 * 64, now: { 0 })
        ring.mark("main_start", at: 1_000_000)
        ring.mainTurn(start: 2_000_000, end: 30_000_000)
        ring.laneJobSink(.files, .userVisible, 3_000_000, 9_000_000)
        ring.mark("first_window_frame_committed", at: 640_000_000)
        let launch = try #require(ring.finish(keeping: HangReport.LaunchTrace.exceedsBudget(record)))
        #expect(ring.heldBytes == 0)
        let trace = try #require(SlowLaunchReporting.trace(of: launch, record: record, tasks: []))
        #expect(trace.firstFrameMs == 640)
        #expect(trace.budgetMs == 180)
        #expect(trace.dropped == launch.overwritten)
        #expect(Set(trace.events.map(\.kind)).isSubset(of: [.mark, .mainTurn, .laneJob]))
        #expect(trace.events.last?.name == "first_window_frame_committed")
        #expect(trace.events.map(\.startMicros) == trace.events.map(\.startMicros).sorted())
        #expect(StartupTrace.SlowLaunchRing.Event.Kind.allCases.map(SlowLaunchReporting.kind) == [
            .mark, .mainTask, .laneTask, .mainTurn, .laneJob,
        ])
    }

    @Test func aTraceWaitsForTheFirstDecisionAndGoesOnlyWhenReportsAreOn() throws {
        let trace = try #require(HangReport.LaunchTrace(launch: LaunchAggregate.Record(
            temperature: .cold, interrupted: false, firstFrame: .milliseconds(900), liveContent: nil, startupComplete: .seconds(2),
            reason: .visiblePaneLoadedIdle), events: [], dropped: 0))
        let collector = HangReportCollector(resolve: { _ in [] }, keepsLaunchTrace: true, schedule: { $0() })
        collector.setEnabled(true)
        let handoff = LaunchTraceHandoff()
        handoff.note(trace, collector: collector)
        #expect(collector.snapshot().launchTrace == nil)
        handoff.decide(true, collector: collector)
        #expect(collector.snapshot().launchTrace == trace)
        let off = HangReportCollector(resolve: { _ in [] }, keepsLaunchTrace: true, schedule: { $0() })
        let dropped = LaunchTraceHandoff()
        dropped.note(trace, collector: off)
        dropped.decide(false, collector: off)
        off.setEnabled(true)
        dropped.decide(true, collector: off)
        #expect(off.snapshot().launchTrace == nil)
    }
}
