import CmuxNextCompat
@testable import CmuxNextHangReports
import Foundation
import Testing

/// The daemon's diagnostic sites in opt-in hang reports and crash reports (p02-threads-233): a site is one
/// sample with the daemon as its source and no path; the same site again adds nothing, whatever kind it
/// names; the schema 3 server rules and the privacy scanner pass the report; the deployed schema keeps none;
/// the sink sends one non-fatal event per site within the blocking budget.
struct DaemonSiteSampleTests {
    private static let builder = HangReportBuilder(classifier: HangReportFixtures.classifier(),
                                                   resolver: HangReportFixtures.FakeResolver(), wireSchema: .v3)

    private static func collector(schema3: Bool = true) -> HangReportCollector {
        HangReportCollector(resolve: { builder.frames(addresses: $0) },
                            resolveBlocking: schema3 ? { builder.frames(blocking: $0) } : nil, schedule: { $0() })
    }

    private static func fsSite(line: UInt32 = 412, kind: String = "fs") throws -> DaemonDiagnosticSite {
        try DaemonDiagnosticSite(family: .blocking, kind: kind, crateName: "cmux-tui-core", fileHash: "9f2c4e1a7b3d5c60",
                                 line: line)
    }

    private static func hangSite() throws -> DaemonDiagnosticSite {
        try DaemonDiagnosticSite(family: .hang, kind: "request", method: "list-workspaces")
    }

    @Test func aDaemonSiteIsOneSampleWithTheDaemonAsItsSource() throws {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteDaemonSite(try Self.fsSite())

        let sample = try #require(collector.snapshot().blocking.first)
        #expect(collector.snapshot().blocking.count == 1)
        #expect(sample.source == .daemon)
        #expect(sample.kind == .blocking)
        #expect(sample.durationMs == 0)
        #expect(sample.frames.isEmpty)
        #expect(sample.blocking == nil)
        #expect(sample.daemon == HangSample.Daemon(family: "blocking", kind: "fs", site: "daemon-cmux-tui-core-9f2c4e1a7b3d5c60-412"))
    }

    @Test func theSameSiteAgainAddsNothingWhateverKindItNames() throws {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteDaemonSite(try Self.fsSite())
        collector.noteDaemonSite(try Self.fsSite())
        collector.noteDaemonSite(try Self.fsSite(kind: "sleep"))
        collector.noteDaemonSite(try Self.fsSite(line: 413))
        collector.noteDaemonSite(try Self.hangSite())
        collector.noteDaemonSite(try Self.hangSite())

        #expect(collector.snapshot().blocking.compactMap(\.daemon?.site) == [
            "daemon-cmux-tui-core-9f2c4e1a7b3d5c60-412", "daemon-cmux-tui-core-9f2c4e1a7b3d5c60-413",
            "daemon-hang-list-workspaces",
        ])
    }

    @Test func theReportPassesTheServerRulesAndThePrivacyScanner() throws {
        let collector = Self.collector()
        collector.setEnabled(true)
        collector.noteDaemonSite(try Self.fsSite())
        collector.noteDaemonSite(try DaemonDiagnosticSite(family: .inversion, kind: "priority-inversion", crateName: "cmux-threads",
                                                          fileHash: "0123456789abcdef", line: 7))
        collector.noteDaemonSite(try Self.hangSite())
        let report = Self.builder.build(context: HangReportFixtures.context(), watchdog: collector.drain(), metricKit: [])
        let body = try HangReport.encoder.encode(report)

        #expect(report.hangs.filter { $0.source == .daemon }.count == 3)
        #expect(HangReportServerRules.violations(in: body) == [])
        #expect(PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms).findings(in: body).isEmpty)
    }

    @Test func aReportOfTheDeployedSchemaKeepsNoDaemonSite() throws {
        let collector = Self.collector(schema3: false)
        collector.setEnabled(true)
        collector.noteDaemonSite(try Self.fsSite())

        #expect(collector.snapshot().isEmpty)
    }

    @Test func aSavedDaemonSampleRoundTrips() throws {
        var aggregate = StallAggregate()
        aggregate.keep(.daemonSite(try Self.hangSite()))
        let decoded = try JSONDecoder().decode(StallAggregate.self, from: JSONEncoder().encode(aggregate))

        #expect(decoded.blocking == aggregate.blocking)
    }

    @Test func theSinkSendsOneNonFatalEventPerDaemonSiteWithinTheBudget() throws {
        let sends = Mutex<[BlockingReportSink.NonFatalEvent]>([])
        let collector = Self.collector()
        collector.setEnabled(true)
        let sink = BlockingReportSink(
            collector: collector,
            nonFatal: .init(consented: { true }, send: { event in sends.withLock { $0.append(event) } }),
            store: .init(load: { [:] }, save: { _ in }))
        sink.record(daemonSite: try Self.fsSite())
        sink.record(daemonSite: try Self.fsSite())
        sink.record(daemonSite: try Self.hangSite())

        let sent = sends.withLock { $0 }
        #expect(sent.map(\.message) == ["daemon blocking: fs", "daemon hang: request"])
        #expect(sent.map(\.type) == ["DaemonBlocking", "DaemonHang"])
        #expect(sent.map { $0.fingerprint.last } == ["daemon-cmux-tui-core-9f2c4e1a7b3d5c60-412", "daemon-hang-list-workspaces"])
        #expect(collector.snapshot().blocking.count == 2)
    }
}
