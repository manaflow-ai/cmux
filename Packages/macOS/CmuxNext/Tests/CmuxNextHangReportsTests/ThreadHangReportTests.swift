@testable import CmuxNextHangReports
import Foundation
import Testing

/// A watched thread's hang in an opt-in hang report (p09-observability-068): one `hangwatch` hang entry that names
/// the registration and its kind, with the thread's frames, in wire schema 3 only (the deployed schema-2 server
/// refuses the source and the key), a name outside the catalog shape written as `other`.
struct ThreadHangReportTests {
    private static func collector() -> HangReportCollector {
        HangReportCollector(resolve: { _ in [HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 1)] },
                            schedule: { $0() })
    }

    private static func builder(_ schema: HangReport.WireSchema) -> HangReportBuilder {
        HangReportBuilder(classifier: HangReportFixtures.classifier(), resolver: HangReportFixtures.FakeResolver(), wireSchema: schema)
    }

    private static func aggregate() -> StallAggregate {
        let collector = collector()
        collector.setEnabled(true)
        collector.noteThreadHang(durationNanos: 2_400_000_000, addresses: [1, 2],
                                 thread: HangSample.WatchedThread(name: "daemon-reader", kind: "io"))
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
        #expect(entry.thread == HangSample.WatchedThread(name: "daemon-reader", kind: "io"))
        #expect(entry.frames == [HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 1)])
        #expect(report.hangs.filter { $0.source == .watchdog }.allSatisfy { $0.thread == nil })
        let body = try HangReport.encoder.encode(report)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains(#""source":"hangwatch""#), "\(text)")
        #expect(text.contains(#""thread":{"kind":"io","name":"daemon-reader"}"#), "\(text)")
        let decoded = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(decoded.hangs == report.hangs)
    }

    @Test func aSchema2ReportCarriesNoHangWatchEntry() throws {
        let report = Self.builder(.v2).build(context: HangReportFixtures.context(), watchdog: Self.aggregate(), metricKit: [])

        #expect(report.hangs.map(\.source) == [.watchdog], "the main thread's hang stays")
        let body = try HangReport.encoder.encode(report)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(!text.contains("hangwatch") && !text.contains("\"thread\""), "a schema-2 server answers 400: \(text)")
    }

    @Test func aHangWithNoStackIsNotKept() {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteThreadHang(durationNanos: 2_400_000_000, addresses: [], thread: .init(name: "daemon-reader", kind: "io"))
        #expect(collector.snapshot().hangs.isEmpty)
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
        aggregate.keep(HangSample(source: .watchdog, kind: .hang, durationMs: 3_000,
                                  frames: [HangReportFrame(image: "AppKit", uuid: HangReportFixtures.appKitUUID, offset: 1)],
                                  thread: .init(name: "daemon-reader", kind: "io")))
        let report = Self.builder(.v3).build(context: HangReportFixtures.context(), watchdog: aggregate, metricKit: [])
        #expect(report.hangs.count == 1)
        #expect(report.hangs.first?.thread == nil)
    }
}
