@testable import CmuxNextHangReports
import Foundation
import Testing

/// The slow-launch trace (p08-startup-111): a launch's ring is attached only when its first frame missed the p95 budget
/// of its temperature, never for an interrupted or windowless launch; off, or with a builder that does not send it,
/// nothing is kept or sent; the report keeps the launch furthest past its budget, names only, at most
/// ``HangReport/maxLaunchTraceEvents`` events, and passes the leak scan and the server's shape rules.
struct LaunchTraceAttachTests {
    private static func launch(_ temperature: LaunchTemperature = .warm, firstFrameMs: Int?, interrupted: Bool = false)
        -> LaunchAggregate.Record {
        LaunchAggregate.Record(temperature: temperature, interrupted: interrupted, firstFrame: firstFrameMs.map { .milliseconds($0) },
                               liveContent: nil, startupComplete: .milliseconds(2_400), reason: .visiblePaneLoadedIdle)
    }

    private static let events: [HangReport.LaunchTrace.Event] = [
        .init(startMicros: 0, durationMicros: 0, kind: .mark, name: "process_start"),
        .init(startMicros: 1_200, durationMicros: 0, kind: .mark, name: "main_start"),
        .init(startMicros: 4_000, durationMicros: 310_000, kind: .mainTask, name: "AppServices.restore"),
        .init(startMicros: 5_000, durationMicros: 42_000, kind: .laneJob, name: "files.userVisible"),
        .init(startMicros: 320_000, durationMicros: 0, kind: .mark, name: "first_window_frame_committed"),
    ]

    private static func trace(_ temperature: LaunchTemperature = .warm, firstFrameMs: Int = 420,
                              events: [HangReport.LaunchTrace.Event] = LaunchTraceAttachTests.events) throws -> HangReport.LaunchTrace {
        try #require(HangReport.LaunchTrace(launch: launch(temperature, firstFrameMs: firstFrameMs), events: events, dropped: 0))
    }

    private static func sending(_ wireSchema: HangReport.WireSchema = .v3, sends: Bool = true) -> HangReportBuilder {
        HangReportBuilder(classifier: HangReportFixtures.classifier(), resolver: HangReportFixtures.builder().resolver,
                          wireSchema: wireSchema, sendsLaunchTrace: sends)
    }

    private static func collector(keeps: Bool = true) -> HangReportCollector {
        HangReportCollector(resolve: { _ in [] }, keepsLaunchTrace: keeps, schedule: { $0() })
    }

    // MARK: the budget

    @Test func onlyAFirstFramePastItsTemperaturesP95BudgetIsSlow() {
        #expect(HangReport.LaunchTrace.firstFrameBudgetMs(.warm) == 180)
        #expect(HangReport.LaunchTrace.firstFrameBudgetMs(.cold) == 360)
        #expect(!HangReport.LaunchTrace.exceedsBudget(Self.launch(.warm, firstFrameMs: 180)))
        #expect(HangReport.LaunchTrace.exceedsBudget(Self.launch(.warm, firstFrameMs: 181)))
        #expect(!HangReport.LaunchTrace.exceedsBudget(Self.launch(.cold, firstFrameMs: 360)))
        #expect(HangReport.LaunchTrace.exceedsBudget(Self.launch(.cold, firstFrameMs: 361)))
        // A lukewarm or undetermined launch is judged by the looser cold budget.
        #expect(!HangReport.LaunchTrace.exceedsBudget(Self.launch(.lukewarm, firstFrameMs: 300)))
        #expect(!HangReport.LaunchTrace.exceedsBudget(Self.launch(.undetermined, firstFrameMs: 300)))
        // Something other than cmux slowed it, or no window showed: never traced.
        #expect(!HangReport.LaunchTrace.exceedsBudget(Self.launch(.warm, firstFrameMs: 5_000, interrupted: true)))
        #expect(!HangReport.LaunchTrace.exceedsBudget(Self.launch(.warm, firstFrameMs: nil)))
    }

    @Test func aLaunchWithinItsBudgetMakesNoTrace() throws {
        #expect(HangReport.LaunchTrace(launch: Self.launch(firstFrameMs: 150), events: Self.events, dropped: 0) == nil)
        let slow = try Self.trace(firstFrameMs: 420)
        #expect(slow.budgetMs == 180)
        #expect(slow.overrunMs == 240)
        #expect(slow.startupCompleteMs == 2_400)
    }

    // MARK: the collector

    @Test func offOrNotSentKeepsNoTrace() throws {
        let trace = try Self.trace()
        let off = Self.collector()
        off.noteLaunchTrace(trace)
        #expect(off.drain().launchTrace == nil)
        let notSent = Self.collector(keeps: false)
        notSent.setEnabled(true)
        notSent.noteLaunchTrace(trace)
        #expect(notSent.drain().isEmpty)
        let on = Self.collector()
        on.setEnabled(true)
        on.noteLaunchTrace(trace)
        #expect(on.snapshot().launchTrace == trace)
        on.setEnabled(false)
        #expect(on.drain().isEmpty)
    }

    @Test func theLaunchFurthestPastItsBudgetIsKeptAndSurvivesThePendingFile() throws {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteLaunchTrace(try Self.trace(firstFrameMs: 300))
        collector.noteLaunchTrace(try Self.trace(.cold, firstFrameMs: 400))  // 40 ms past: kept out
        #expect(collector.snapshot().launchTrace?.firstFrameMs == 300)
        var saved = StallAggregate()
        saved.keep(launchTrace: try Self.trace(firstFrameMs: 900))
        let decoded = try JSONDecoder().decode(StallAggregate.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
        collector.merge(decoded)
        #expect(collector.drain().launchTrace?.firstFrameMs == 900)
        // A build that sends no launch trace drops the one an earlier build saved.
        let notSent = Self.collector(keeps: false)
        notSent.setEnabled(true)
        notSent.merge(decoded)
        #expect(notSent.drain().isEmpty)
        // A pending file from before launch traces still decodes.
        let old = #"{"counts":[0,0,0,0,0,0,0,0],"hangs":[],"stalls":[]}"#
        #expect(try JSONDecoder().decode(StallAggregate.self, from: Data(old.utf8)).launchTrace == nil)
    }

    // MARK: the report

    @Test func aSlowLaunchsReportHoldsTheRingAndPassesTheLeakScan() throws {
        var watchdog = StallAggregate()
        watchdog.record(launch: Self.launch(firstFrameMs: 420))
        watchdog.keep(launchTrace: try Self.trace(firstFrameMs: 420))
        let report = Self.sending().build(context: HangReportFixtures.context(), watchdog: watchdog, metricKit: [])
        let trace = try #require(report.launchTrace)
        #expect(trace.events == Self.events)
        #expect(!report.hasNoFindings)
        let body = try HangReport.encoder.encode(report)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wire = try #require(json["launch_trace"] as? [String: Any])
        #expect(Set(wire.keys) == ["temperature", "reason", "first_frame_ms", "budget_ms", "startup_complete_ms", "dropped", "events"])
        let first = try #require((wire["events"] as? [[Any]])?.dropFirst(2).first)
        #expect(first.count == 4)
        #expect(first[0] as? Int == 4_000)
        #expect(first[1] as? Int == 310_000)
        #expect(first[2] as? String == "main_task")
        #expect(first[3] as? String == "AppServices.restore")
        #expect(try JSONDecoder().decode(HangReport.self, from: body) == report)
    }

    @Test func aBuilderThatDoesNotSendItOrSchemaTwoCarriesNoTrace() throws {
        var watchdog = StallAggregate()
        watchdog.keep(launchTrace: try Self.trace())
        watchdog.count(durationMs: 300)
        for builder in [Self.sending(sends: false), Self.sending(.v2), HangReportFixtures.builder(wireSchema: .v3)] {
            #expect(!builder.carriesLaunchTrace)
            let report = builder.build(context: HangReportFixtures.context(), watchdog: watchdog, metricKit: [])
            #expect(report.launchTrace == nil)
            let body = try HangReport.encoder.encode(report)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["launch_trace"] == nil)
            // What the server accepts today: no unknown key.
            #expect(HangReportServerRules.violations(in: body).isEmpty)
        }
    }

    @Test func aNameThatIsNotACodeIdentifierOrHoldsAPersonalTermIsOther() throws {
        let names = ["/Users/alice/notes.md", "AliceTask.run", "reveal.sidebar", "has space", "launch.temperature.warm"]
        let events = names.enumerated().map { index, name in
            HangReport.LaunchTrace.Event(startMicros: UInt64(index), durationMicros: 0, kind: .mark, name: name)
        }
        var watchdog = StallAggregate()
        watchdog.keep(launchTrace: try Self.trace(events: events))
        let report = Self.sending().build(context: HangReportFixtures.context(), watchdog: watchdog, metricKit: [])
        #expect(report.launchTrace?.events.map(\.name) == ["other", "other", "reveal.sidebar", "other", "launch.temperature.warm"])
        let body = try HangReport.encoder.encode(report)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
    }

    /// A pending file edited on disk: its budget is this build's, a first frame within it sends nothing, and the
    /// numbers are clamped.
    @Test func anEditedPendingTraceIsRebuiltBeforeItIsSent() throws {
        let edited = HangReport.LaunchTrace(temperature: .warm, reason: .failsafe, firstFrameMs: 170, budgetMs: 10,
                                            startupCompleteMs: -3, dropped: -9, events: Self.events)
        var within = StallAggregate()
        within.keep(launchTrace: edited)
        #expect(Self.sending().build(context: HangReportFixtures.context(), watchdog: within, metricKit: []).launchTrace == nil)
        var huge = edited
        huge.firstFrameMs = Int.max
        huge.events = [.init(startMicros: .max, durationMicros: 7, kind: .mark, name: "main_start")]
        var past = StallAggregate()
        past.keep(launchTrace: huge)
        let sent = try #require(Self.sending().build(context: HangReportFixtures.context(), watchdog: past, metricKit: []).launchTrace)
        #expect(sent.budgetMs == 180)
        #expect(sent.firstFrameMs == HistogramBucket.maxMs)
        #expect(sent.startupCompleteMs == 0)
        #expect(sent.dropped == 0)
        #expect(sent.events == [.init(startMicros: HangReportBuilder.maxLaunchTraceMicros, durationMicros: 0, kind: .mark, name: "main_start")])
    }

    /// More events than a report carries: every mark, then the longest slices, by start time; the cut is counted.
    @Test func aLongRingIsCutToItsMarksAndLongestSlices() throws {
        let marks = (0..<40).map { HangReport.LaunchTrace.Event(startMicros: UInt64($0) * 10_000, durationMicros: 0, kind: .mark, name: "m\($0)") }
        let slices = (0..<300).map {
            HangReport.LaunchTrace.Event(startMicros: UInt64($0) * 1_000 + 5, durationMicros: UInt64($0) * 100 + 1_000, kind: .laneJob,
                                         name: "files.bestEffort")
        }
        var watchdog = StallAggregate()
        watchdog.keep(launchTrace: try #require(HangReport.LaunchTrace(launch: Self.launch(firstFrameMs: 500), events: slices + marks,
                                                                       dropped: 12)))
        let sent = try #require(Self.sending().build(context: HangReportFixtures.context(), watchdog: watchdog, metricKit: []).launchTrace)
        #expect(sent.events.count == HangReport.maxLaunchTraceEvents)
        #expect(sent.events.filter { $0.kind == .mark }.count == 40)
        let kept = sent.events.filter { $0.kind == .laneJob }.map(\.durationMicros)
        #expect(kept.count == HangReport.maxLaunchTraceEvents - 40)
        #expect(kept.min() == UInt64(300 - kept.count) * 100 + 1_000)
        #expect(sent.events.map(\.startMicros) == sent.events.map(\.startMicros).sorted())
        #expect(sent.dropped == 12 + 340 - HangReport.maxLaunchTraceEvents)
    }

    @Test func aBodyOverItsCapDropsTheTraceBeforeAnyHang() {
        var report = Self.sending().build(context: HangReportFixtures.context(), watchdog: StallAggregate(), metricKit: [])
        report.hangs = [HangSample(source: .watchdog, kind: .stall, durationMs: 400, frames: [])]
        let many = (0..<5_000).map {
            HangReport.LaunchTrace.Event(startMicros: UInt64($0), durationMicros: 1_000, kind: .mainTurn, name: "main.turn")
        }
        report.launchTrace = HangReport.LaunchTrace(temperature: .warm, reason: .visiblePaneLoadedIdle, firstFrameMs: 400, budgetMs: 180,
                                                    startupCompleteMs: 900, dropped: 0, events: many)
        let fitted = HangReportService.fitted(report)
        #expect(fitted.launchTrace == nil)
        #expect(fitted.hangs.count == 1)
    }
}
