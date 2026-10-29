@testable import CmuxNextHangReports
import Foundation
import Testing

/// A watched thread's hang in an opt-in hang report: one `hangwatch` hang entry that names
/// the registration and its kind, with the thread's frames, in wire schema 3 only (the deployed schema-2 server
/// refuses the source and the key), a name outside the catalog shape written as `other`, in slots of their own so
/// they never push a main-thread hang out.
struct ThreadHangReportTests {
    private static let frame = HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 1)
    private static let reader = HangSample.WatchedThread(name: "daemon-reader", kind: "io")

    /// `keepsThreadHangs` as the app passes it: its builder's `carriesThreadHangs`.
    private static func collector(keepsThreadHangs: Bool = true) -> HangReportCollector {
        HangReportCollector(resolve: { _ in [frame] }, keepsThreadHangs: keepsThreadHangs, schedule: { $0() })
    }

    private static func builder(_ schema: HangReport.WireSchema) -> HangReportBuilder {
        HangReportBuilder(classifier: HangReportFixtures.classifier(), resolver: HangReportFixtures.FakeResolver(), wireSchema: schema)
    }

    private static func aggregate() -> StallAggregate {
        let collector = collector()
        collector.setEnabled(true)
        collector.noteThreadHang(durationNanos: 2_400_000_000, addresses: [1, 2], thread: reader)
        collector.noteHang(durationNanos: 3_000_000_000, addresses: [1])
        return collector.drain()
    }

    @Test func aSchema3ReportCarriesOneHangWatchEntryWithItsThreadAndFrames() throws {
        let report = Self.builder(.v3).build(context: HangReportFixtures.context(), watchdog: Self.aggregate(), metricKit: [])

        let entries = report.hangs.filter { $0.source == .hangWatch }
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.kind == .hang)
        #expect(entry.durationMs == 2_400)
        #expect(entry.thread == Self.reader)
        #expect(entry.frames == [Self.frame])
        #expect(report.hangs.filter { $0.source == .watchdog }.allSatisfy { $0.thread == nil })
        let body = try HangReport.encoder.encode(report)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains(#""source":"hangwatch""#), "\(text)")
        #expect(text.contains(#""thread":{"kind":"io","name":"daemon-reader"}"#), "\(text)")
        let decoded = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(decoded.hangs == report.hangs)
    }

    /// An aggregate a schema-3 build saved, sent by a schema-2 build: the thread hang stays out.
    @Test func aSchema2ReportCarriesNoHangWatchEntry() throws {
        let report = Self.builder(.v2).build(context: HangReportFixtures.context(), watchdog: Self.aggregate(), metricKit: [])

        #expect(report.hangs.map(\.source) == [.watchdog], "the main thread's hang stays")
        let body = try HangReport.encoder.encode(report)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(!text.contains("hangwatch") && !text.contains("\"thread\""), "a schema-2 server answers 400: \(text)")
    }

    /// Eight main-thread hangs fill their slots; a longer thread hang after them pushes none out, in either schema.
    @Test(arguments: [HangReport.WireSchema.v2, .v3])
    func aThreadHangNeverPushesAMainThreadHangOut(schema: HangReport.WireSchema) {
        let collector = Self.collector(keepsThreadHangs: schema.carriesThreadHangs)
        collector.setEnabled(true)
        for index in 0..<StallAggregate.maxSamples {
            collector.noteHang(durationNanos: UInt64(2_100 + index) * 1_000_000, addresses: [1])
        }
        collector.noteThreadHang(durationNanos: 2_400_000_000, addresses: [1], thread: Self.reader)
        let aggregate = collector.drain()
        #expect(aggregate.hangs.count == StallAggregate.maxSamples)
        #expect(aggregate.threadHangs.count == (schema.carriesThreadHangs ? 1 : 0), "a schema-2 collector keeps none")

        let report = Self.builder(schema).build(context: HangReportFixtures.context(), watchdog: aggregate, metricKit: [])
        #expect(report.hangs.filter { $0.source == .watchdog }.count == StallAggregate.maxSamples)
        #expect(report.hangs.filter { $0.source == .hangWatch }.count == (schema.carriesThreadHangs ? 1 : 0))
    }

    /// A schema-2 build drops the thread hangs a schema-3 launch saved, and keeps the main thread's.
    @Test func aSchema2CollectorDropsSavedThreadHangsOnMerge() {
        let collector = Self.collector(keepsThreadHangs: false)
        collector.setEnabled(true)
        collector.merge(Self.aggregate())
        let merged = collector.snapshot()
        #expect(merged.threadHangs.isEmpty)
        #expect(merged.hangs.map(\.source) == [.watchdog])
    }

    /// A pending file that put a thread hang among the main thread's: merged into its own slots.
    @Test func aMergedHangWatchSampleGoesToTheThreadSlots() {
        var saved = StallAggregate()
        saved.keep(.threadHang(Self.reader, durationMs: 2_400, frames: [Self.frame]))
        var aggregate = StallAggregate()
        aggregate.merge(saved)
        #expect(aggregate.hangs.isEmpty)
        #expect(aggregate.threadHangs.map(\.thread) == [Self.reader])
        #expect(!aggregate.isEmpty && aggregate.isEmptyWithoutLaunches, "a schema-2 report has nothing to send")
    }

    /// A watched thread's hang takes the report's black box, as a main-thread hang of a second does.
    @Test func aThreadHangTakesTheBlackBox() async {
        let jobs = HangReportFieldDataFlowTests.Jobs()
        let event = HangReportFieldDataFlowTests.event
        let collector = HangReportCollector(resolve: { _ in [] }, captureBlackBox: { [event] }, keepsThreadHangs: true,
                                            schedule: { $0() }, scheduleCapture: { jobs.append($0) })
        collector.noteThreadHang(durationNanos: 2_000_000_000, addresses: [1], thread: Self.reader)
        #expect(jobs.scheduled.isEmpty, "off: nothing is read")
        collector.setEnabled(true)
        collector.noteThreadHang(durationNanos: 2_000_000_000, addresses: [1], thread: Self.reader)
        #expect(jobs.scheduled.count == 1)
        await jobs.scheduled[0]()
        #expect(collector.takeBlackBox() == [event])
    }

    /// The Chromium Host's UI hangs: the host measured them and sends no stack, so each is kept
    /// frameless as a hang of `chromium-host.ui`, in the thread slots, never among the app's own hangs; a schema-2
    /// collector keeps none, and a schema-3 report with one passes the server's rules.
    @Test func aChromiumHostHangIsKeptAsTheHostsUIThread() throws {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteHostHang(durationNanos: 400_000_000)
        let aggregate = collector.drain()
        #expect(aggregate.hangs.isEmpty && aggregate.stalls.isEmpty)
        #expect(aggregate.threadHangs.map(\.thread) == [HangSample.WatchedThread(name: "chromium-host.ui", kind: "main")])
        #expect(aggregate.threadHangs.map(\.durationMs) == [400])
        let report = Self.builder(.v3).build(context: HangReportFixtures.context(), watchdog: aggregate, metricKit: [])
        #expect(HangReportServerRules.violations(in: try HangReport.encoder.encode(report)).isEmpty)

        let schema2 = Self.collector(keepsThreadHangs: false)
        schema2.setEnabled(true)
        schema2.noteHostHang(durationNanos: 400_000_000)
        #expect(schema2.snapshot().threadHangs.isEmpty)
    }

    @Test func aHangWithNoStackIsNotKept() {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteThreadHang(durationNanos: 2_400_000_000, addresses: [], thread: Self.reader)
        #expect(collector.snapshot().threadHangs.isEmpty)
    }

    @Test func aNameOrKindOutsideTheCatalogShapeIsOther() throws {
        #expect(HangSample.WatchedThread(name: "/Users/alice/run.sh", kind: "io").name == "other")
        #expect(HangSample.WatchedThread(name: "Alice's lane", kind: "io").name == "other")
        #expect(HangSample.WatchedThread(name: String(repeating: "a", count: 49), kind: "io").name == "other")
        #expect(HangSample.WatchedThread(name: "terminal-output", kind: "lane") == .init(name: "terminal-output", kind: "lane"))
        #expect(HangSample.WatchedThread(name: "terminal-output", kind: "secret").kind == "other")
        let path = Data(#"{"name":"/Users/alice","kind":"nope"}"#.utf8)
        #expect(try JSONDecoder().decode(HangSample.WatchedThread.self, from: path) == .init(name: "other", kind: "other"))
    }

    /// A watchdog sample that a pending file says names a thread sends none.
    @Test func onlyAHangWatchSampleNamesAThread() {
        var aggregate = StallAggregate()
        aggregate.keep(HangSample(source: .watchdog, kind: .hang, durationMs: 3_000, frames: [Self.frame], thread: Self.reader))
        let report = Self.builder(.v3).build(context: HangReportFixtures.context(), watchdog: aggregate, metricKit: [])
        #expect(report.hangs.count == 1)
        #expect(report.hangs.first?.thread == nil)
    }
}
