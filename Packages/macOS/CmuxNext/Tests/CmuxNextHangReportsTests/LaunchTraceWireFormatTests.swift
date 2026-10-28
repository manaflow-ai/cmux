@testable import CmuxNextHangReports
import Foundation
import Testing

/// Schema 3's `launch_trace` on the wire (p08-startup-111): ``golden3LaunchTrace`` is byte for byte
/// web/tests/fixtures/hang-report-schema3-launch-trace.json, which the server's decoder accepts
/// (web/tests/hang-reports-schema3.test.ts checks both), so client and server cannot drift.
struct LaunchTraceWireFormatTests {
    static let golden3LaunchTrace = #"{"app":{"build":"2123456789012","channel":"nightly","version":"0.70.0"},"counts":{"panes":"6-10","tabs":"31-100","windows":"1","workspaces":"11-30"},"cpuExceptions":[],"day":"2026-10-23","hangs":[],"hardware":{"arch":"arm64","chip":"Apple M4 Pro","cores":14,"memoryGB":48},"installId":"0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20","intervals":[],"launch_trace":{"budget_ms":180,"dropped":3,"events":[[0,0,"mark","process_start"],[1200,0,"mark","main_start"],[4000,310000,"main_task","AppServices.restore"],[5000,42000,"lane_job","files.userVisible"],[320000,0,"mark","first_window_frame_committed"]],"first_frame_ms":420,"reason":"visiblePaneLoadedIdle","startup_complete_ms":2400,"temperature":"warm"},"metrics":{"hangTime":[],"launchExtended":[],"launchFirstDraw":[],"launchOptimizedFirstDraw":[],"launchResume":[]},"os":{"version":"15.7.4"},"reportId":"5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11","schema":3,"stallHistogram":[]}"#

    @Test func theLaunchTraceGoldenRoundTripsAndPassesTheScanAndTheServerRules() throws {
        let body = Data(Self.golden3LaunchTrace.utf8)
        let report = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(String(decoding: try HangReport.encoder.encode(report), as: UTF8.self) == Self.golden3LaunchTrace)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        // What a sending builder writes from the same trace.
        let trace = try #require(report.launchTrace)
        var watchdog = StallAggregate()
        watchdog.keep(launchTrace: trace)
        let builder = HangReportBuilder(classifier: HangReportFixtures.classifier(), resolver: HangReportFixtures.builder().resolver,
                                        wireSchema: .v3, sendsLaunchTrace: true)
        #expect(builder.build(context: HangReportFixtures.context(), watchdog: watchdog, metricKit: []).launchTrace == trace)
    }

    @Test func theServerRulesRefuseWhatTheDecoderRefuses() {
        let cases = [
            (#""kind":"main_task""#, #""main_task""#, #""main_thread""#),
            (#""mark","main_start""#, #"[1200,0,"mark","main_start"]"#, #"[1200,5,"mark","main_start"]"#),
            (#""first_frame_ms""#, #""first_frame_ms":420"#, #""first_frame_ms":180"#),
            (#""temperature""#, #""temperature":"warm""#, #""temperature":"hot""#),
            (#""name""#, #""AppServices.restore""#, #""/Users/alice""#),
        ]
        for (label, from, to) in cases {
            let edited = Self.golden3LaunchTrace.replacingOccurrences(of: from, with: to)
            #expect(edited != Self.golden3LaunchTrace, "\(label)")
            #expect(!HangReportServerRules.violations(in: Data(edited.utf8)).isEmpty, "\(label)")
        }
    }
}
