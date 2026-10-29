@testable import CmuxNextHangReports
import Foundation
import Testing

/// Launch milestones by temperature and completion reasons: bucketed, split by
/// temperature, interrupted launches left out of the durations, saved with the pending aggregate,
/// off records nothing, a schema-3 report's JSON holds them and passes the leak scan, and a
/// schema-2 report (what the server accepts today) never carries them.
struct LaunchHistogramTests {
    private static func warm() -> LaunchAggregate.Record {
        LaunchAggregate.Record(temperature: .warm, interrupted: false, firstFrame: .milliseconds(240),
                               liveContent: .milliseconds(310), startupComplete: .milliseconds(420),
                               reason: .visiblePaneLoadedIdle)
    }

    private static func cold() -> LaunchAggregate.Record {
        LaunchAggregate.Record(temperature: .cold, interrupted: false, firstFrame: .milliseconds(1_300), liveContent: nil,
                               startupComplete: .milliseconds(2_600), reason: .visiblePaneTimedOut)
    }

    private static func interrupted() -> LaunchAggregate.Record {
        LaunchAggregate.Record(temperature: .warm, interrupted: true, firstFrame: nil, liveContent: nil,
                               startupComplete: .milliseconds(9_000), reason: .noWindow)
    }

    /// The wire bytes of the three launches above.
    static let golden = #"{"completionReasons":[{"count":1,"reason":"visiblePaneLoadedIdle"},{"count":1,"reason":"visiblePaneTimedOut"},{"count":1,"reason":"noWindow"}],"launchFirstFrame":[{"buckets":[{"count":1,"highMs":1500,"lowMs":1250}],"count":1,"temperature":"cold"},{"buckets":[{"count":1,"highMs":300,"lowMs":200}],"count":1,"temperature":"warm"}],"launchLiveContent":[{"buckets":[{"count":1,"highMs":400,"lowMs":300}],"count":1,"temperature":"warm"}],"launchStartupComplete":[{"buckets":[{"count":1,"highMs":3000,"lowMs":2500}],"count":1,"temperature":"cold"},{"buckets":[{"count":1,"highMs":500,"lowMs":400}],"count":1,"temperature":"warm"}]}"#

    private func collector() -> HangReportCollector {
        HangReportCollector(resolve: { _ in [] }, schedule: { $0() })
    }

    @Test func bucketsCoverZeroToOneDay() {
        #expect(LaunchAggregate.bucket(milliseconds: 0) == HistogramBucket(lowMs: 0, highMs: 100, count: 1))
        #expect(LaunchAggregate.bucket(milliseconds: 99) == HistogramBucket(lowMs: 0, highMs: 100, count: 1))
        #expect(LaunchAggregate.bucket(milliseconds: 100) == HistogramBucket(lowMs: 100, highMs: 200, count: 1))
        #expect(LaunchAggregate.bucket(milliseconds: 1_499) == HistogramBucket(lowMs: 1_250, highMs: 1_500, count: 1))
        #expect(LaunchAggregate.bucket(milliseconds: 60_000)
            == HistogramBucket(lowMs: 60_000, highMs: HistogramBucket.maxMs, count: 1))
        #expect(LaunchAggregate.bucket(milliseconds: -5) == HistogramBucket(lowMs: 0, highMs: 100, count: 1))
        #expect(LaunchAggregate.bucketEdgesMs.count < HistogramBucket.maxBuckets)
    }

    @Test func durationsAreWholeMillisecondsClamped() {
        #expect(LaunchAggregate.milliseconds(.milliseconds(240)) == 240)
        #expect(LaunchAggregate.milliseconds(.microseconds(1_999)) == 1)
        #expect(LaunchAggregate.milliseconds(.seconds(-1)) == 0)
        #expect(LaunchAggregate.milliseconds(.seconds(10_000_000)) == HistogramBucket.maxMs)
    }

    @Test func launchesSplitByTemperatureAndInterruptedOnesCountOnlyTheirReason() {
        var launches = LaunchAggregate()
        launches.record(Self.warm())
        launches.record(Self.warm())
        launches.record(Self.cold())
        launches.record(Self.interrupted())
        #expect(launches.launchFirstFrame.map(\.temperature) == [.cold, .warm])
        #expect(launches.launchFirstFrame.map(\.count) == [1, 2])
        #expect(launches.launchFirstFrame.last?.buckets == [HistogramBucket(lowMs: 200, highMs: 300, count: 2)])
        // No live content before completion: the cold launch is not in that histogram.
        #expect(launches.launchLiveContent.map(\.temperature) == [.warm])
        // The interrupted launch's 9 s is in no duration histogram.
        #expect(launches.launchStartupComplete.flatMap(\.buckets).allSatisfy { $0.lowMs < 9_000 })
        #expect(launches.launchStartupComplete.map(\.count) == [1, 2])
        #expect(launches.completionReasons == [
            LaunchReasonCount(reason: .visiblePaneLoadedIdle, count: 2),
            LaunchReasonCount(reason: .visiblePaneTimedOut, count: 1),
            LaunchReasonCount(reason: .noWindow, count: 1),
        ])
    }

    @Test func offRecordsNoLaunch() {
        let collector = collector()
        collector.noteLaunch(Self.warm())
        #expect(collector.drain().isEmpty)
        collector.setEnabled(true)
        collector.noteLaunch(Self.warm())
        #expect(collector.snapshot().launches.completionReasons.map(\.count) == [1])
        collector.setEnabled(false)
        #expect(collector.drain().isEmpty)
    }

    @Test func launchesSurviveThePendingFileAndMerge() throws {
        var saved = StallAggregate()
        saved.record(launch: Self.warm())
        let decoded = try JSONDecoder().decode(StallAggregate.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
        let collector = collector()
        collector.setEnabled(true)
        collector.noteLaunch(Self.warm())
        collector.merge(decoded)
        let merged = collector.drain()
        #expect(merged.launches.launchFirstFrame == [
            LaunchHistogram(temperature: .warm, count: 2, buckets: [HistogramBucket(lowMs: 200, highMs: 300, count: 2)]),
        ])
    }

    @Test func aPendingFileFromBeforeLaunchHistogramsStillDecodes() throws {
        let old = #"{"counts":[1,0,0,0,0,0,0,0],"hangs":[],"stalls":[]}"#
        let decoded = try JSONDecoder().decode(StallAggregate.self, from: Data(old.utf8))
        #expect(decoded.launches.isEmpty)
        #expect(decoded.histogram == [HistogramBucket(lowMs: 50, highMs: 100, count: 1)])
    }

    @Test func anEditedPendingFileIsBoundedBeforeItIsSent() throws {
        let edited = #"{"completionReasons":[{"count":-4,"reason":"failsafe"},{"count":2,"reason":"failsafe"}],"launchFirstFrame":[{"buckets":[{"count":3,"highMs":300,"lowMs":200}],"count":3,"temperature":"warm"},{"buckets":[{"count":1,"highMs":300,"lowMs":200}],"count":1,"temperature":"warm"}],"launchLiveContent":[],"launchStartupComplete":[{"buckets":[],"count":-1,"temperature":"cold"}]}"#
        let launches = try JSONDecoder().decode(LaunchAggregate.self, from: Data(edited.utf8))
        let sent = try #require(HangReportBuilder.launches(launches))
        #expect(sent.launchFirstFrame == [
            LaunchHistogram(temperature: .warm, count: 4, buckets: [HistogramBucket(lowMs: 200, highMs: 300, count: 4)]),
        ])
        #expect(sent.launchStartupComplete.isEmpty)
        #expect(sent.completionReasons == [LaunchReasonCount(reason: .failsafe, count: 2)])
        // A temperature or reason outside the closed set does not decode at all.
        let unknown = #"{"completionReasons":[{"count":1,"reason":"alice"}],"launchFirstFrame":[],"launchLiveContent":[],"launchStartupComplete":[]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LaunchAggregate.self, from: Data(unknown.utf8)) }
    }

    @Test func aReportJSONHoldsTheLaunchHistogramsAndPassesTheLeakScan() throws {
        let collector = collector()
        collector.setEnabled(true)
        collector.noteLaunch(Self.warm())
        collector.noteLaunch(Self.cold())
        collector.noteLaunch(Self.interrupted())
        let report = HangReportFixtures.builder(wireSchema: .v3).build(context: HangReportFixtures.context(),
                                                                       watchdog: collector.drain(), metricKit: [])
        #expect(report.schema == 3)
        #expect(!report.hasNoFindings)
        let body = try HangReport.encoder.encode(report)
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
        let launches = try HangReport.encoder.encode(try #require(report.launches))
        #expect(String(decoding: launches, as: UTF8.self) == Self.golden)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wire = try #require(json["launches"] as? [String: Any])
        #expect(Set(wire.keys) == ["launchFirstFrame", "launchStartupComplete", "launchLiveContent", "completionReasons"])
        let decoded = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(decoded == report)
    }

    @Test func aSchemaTwoReportCarriesNoLaunches() throws {
        var watchdog = StallAggregate()
        watchdog.record(launch: Self.warm())
        watchdog.count(durationMs: 300)
        let report = HangReportFixtures.builder().build(context: HangReportFixtures.context(), watchdog: watchdog, metricKit: [])
        #expect(HangReport.schemaVersion == 2)
        #expect(report.schema == 2)
        #expect(report.launches == nil)
        let json = try #require(try JSONSerialization.jsonObject(with: HangReport.encoder.encode(report)) as? [String: Any])
        #expect(json["launches"] == nil)
        #expect(json["schema"] as? Int == 2)
    }

    /// Personal terms that are parts of the launch vocabulary ("Luke" in `lukewarm`, "pane" in
    /// `visiblePaneTimedOut`, "fail" in `failsafe`) must not refuse every report that holds them.
    @Test func everyTemperatureAndReasonPassesTheLeakScanForNamesInsideThem() throws {
        var watchdog = StallAggregate()
        for temperature in LaunchTemperature.allCases {
            for reason in LaunchCompletionReason.allCases {
                watchdog.record(launch: LaunchAggregate.Record(temperature: temperature, interrupted: false,
                                                               firstFrame: .milliseconds(200), liveContent: .milliseconds(300),
                                                               startupComplete: .milliseconds(400), reason: reason))
            }
        }
        let report = HangReportFixtures.builder(wireSchema: .v3).build(context: HangReportFixtures.context(),
                                                                       watchdog: watchdog, metricKit: [])
        let launches = try #require(report.launches)
        #expect(launches.launchFirstFrame.count == LaunchTemperature.allCases.count)
        #expect(launches.completionReasons.count == LaunchCompletionReason.allCases.count)
        let terms = ["Luke", "pane", "fail", "Safe", "Wind", "Time", "Loaded", "Visible", "Daemon", "Undetermined"]
        #expect(PrivacyLeakScanner(forbiddenTerms: terms).findings(in: try HangReport.encoder.encode(report)).isEmpty)
        // A term outside the vocabulary is still found.
        #expect(!PrivacyLeakScanner(forbiddenTerms: ["Liddell"]).findings(in: Data(#"{"a":"liddell"}"#.utf8)).isEmpty)
    }

    @Test func aReportWithoutLaunchesHasNoLaunchesKey() throws {
        let report = HangReportFixtures.builder(wireSchema: .v3).build(context: HangReportFixtures.context(), watchdog: StallAggregate(),
                                                        metricKit: [])
        #expect(report.launches == nil)
        #expect(report.hasNoFindings)
        let json = try #require(try JSONSerialization.jsonObject(with: HangReport.encoder.encode(report)) as? [String: Any])
        #expect(json["launches"] == nil)
    }
}
