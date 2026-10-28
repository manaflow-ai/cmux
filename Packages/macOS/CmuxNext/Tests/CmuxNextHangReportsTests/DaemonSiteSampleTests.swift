import CmuxNextCompat
@testable import CmuxNextHangReports
import Foundation
import Testing

/// The daemon's diagnostic sites in opt-in hang reports and crash reports: a site is one
/// sample with the daemon as its source and no path; the same site again adds nothing, whatever kind it
/// names; the schema 3 server rules and the privacy scanner pass the report; the deployed schema keeps none;
/// the sink sends one non-fatal event per site within the blocking budget.
struct DaemonSiteSampleTests {
    private static let builder = HangReportBuilder(classifier: HangReportFixtures.classifier(),
                                                   resolver: HangReportFixtures.FakeResolver(), wireSchema: .v3)

    private static func collector(schema3: Bool = true) -> HangReportCollector {
        let resolveBlocking: HangReportCollector.ResolveBlocking?
        if schema3 {
            resolveBlocking = { Self.builder.frames(blocking: $0) }
        } else {
            resolveBlocking = nil
        }
        return HangReportCollector(resolve: { Self.builder.frames(addresses: $0) }, resolveBlocking: resolveBlocking,
                                   schedule: { $0() })
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

    /// A saved store of last-sent times and of the daemon-site ledger, as the app's defaults keep them across
    /// launches; each save is recorded.
    final class SavedState: Sendable {
        private let ledger = Mutex(DaemonSiteLedger())
        private let ledgerSaves = Mutex<[DaemonSiteLedger]>([])
        private let lastSent = Mutex<[String: Date]>([:])
        private let lastSentSaves = Mutex<[[String: Date]]>([])
        private let daemonLastSent = Mutex<[String: Date]>([:])
        private let daemonLastSentSaves = Mutex<[[String: Date]]>([])

        var ledgers: [DaemonSiteLedger] { ledgerSaves.withLock { $0 } }
        var savedDaemonTimes: [[String: Date]] { daemonLastSentSaves.withLock { $0 } }

        var ledgerStore: DaemonSiteLedger.Store {
            .init(load: { self.ledger.withLock { $0 } },
                  save: { saved in
                      self.ledger.withLock { $0 = saved }
                      self.ledgerSaves.withLock { $0.append(saved) }
                  })
        }

        var store: BlockingReportSink.LastSentStore {
            .init(load: { self.lastSent.withLock { $0 } },
                  save: { saved in
                      self.lastSent.withLock { $0 = saved }
                      self.lastSentSaves.withLock { $0.append(saved) }
                  })
        }

        var daemonStore: BlockingReportSink.LastSentStore {
            .init(load: { self.daemonLastSent.withLock { $0 } },
                  save: { saved in
                      self.daemonLastSent.withLock { $0 = saved }
                      self.daemonLastSentSaves.withLock { $0.append(saved) }
                  })
        }
    }

    /// One app launch's sink over `saved`, its collector, and the events it sent.
    private static func launch(_ saved: SavedState, consented: Bool = true)
        -> (sink: BlockingReportSink, collector: HangReportCollector, sent: @Sendable () -> [BlockingReportSink.NonFatalEvent]) {
        let sends = Mutex<[BlockingReportSink.NonFatalEvent]>([])
        let collector = Self.collector()
        collector.setEnabled(true)
        let sink = BlockingReportSink(
            collector: collector,
            nonFatal: .init(consented: { consented }, send: { event in sends.withLock { $0.append(event) } }),
            store: saved.store, daemonStore: saved.daemonStore, daemonSites: saved.ledgerStore)
        return (sink, collector, { sends.withLock { $0 } })
    }

    private static let bootLife = DaemonDiagnosticSite.Sighting.life(pid: 4242, generation: "0b6f5c1e-2d1a-4c3b-9e8f-7a6b5c4d3e2f")

    private static func sighting(_ site: DaemonDiagnosticSite, life: String = bootLife) -> DaemonDiagnosticSite.Sighting {
        DaemonDiagnosticSite.Sighting(site: site, daemonLife: life)
    }

    @Test func theSinkSendsOneNonFatalEventPerDaemonSiteWithinTheBudget() throws {
        let launch = Self.launch(SavedState())
        launch.sink.record(daemonSite: Self.sighting(try Self.fsSite()))
        launch.sink.record(daemonSite: Self.sighting(try Self.fsSite()))
        launch.sink.record(daemonSite: Self.sighting(try Self.hangSite()))

        let sent = launch.sent()
        #expect(sent.map(\.message) == ["daemon blocking: fs", "daemon hang: request"])
        #expect(sent.map(\.type) == ["DaemonBlocking", "DaemonHang"])
        #expect(sent.map { $0.fingerprint.last } == ["daemon-cmux-tui-core-9f2c4e1a7b3d5c60-412", "daemon-hang-list-workspaces"])
        #expect(launch.collector.snapshot().blocking.count == 2)
    }

    /// The headless daemon outlives the app: a relaunch against the same daemon life gets every site replayed,
    /// and adds no sample and no event; a new daemon life reports its sites again.
    @Test func twoLaunchesAgainstOneDaemonLifeReportEachSiteOnce() throws {
        let saved = SavedState()
        let first = Self.launch(saved)
        first.sink.record(daemonSite: Self.sighting(try Self.fsSite()))
        first.sink.record(daemonSite: Self.sighting(try Self.hangSite()))
        #expect(first.collector.snapshot().blocking.count == 2)
        #expect(first.sent().count == 2)

        // The next launch: its report was sent and drained, the daemon replays the same life's sites.
        let second = Self.launch(saved)
        second.sink.record(daemonSite: Self.sighting(try Self.fsSite()))
        second.sink.record(daemonSite: Self.sighting(try Self.hangSite()))
        #expect(second.collector.snapshot().blocking.isEmpty)
        #expect(second.sent().isEmpty)
        #expect(first.collector.snapshot().blocking.count + second.collector.snapshot().blocking.count == 2)

        // A daemon restart is a new life: its first sighting of a site is reported (the 24 h rule holds Sentry).
        second.sink.record(daemonSite: Self.sighting(try Self.fsSite(), life: "4243-new-boot"))
        #expect(second.collector.snapshot().blocking.compactMap(\.daemon?.site) == ["daemon-cmux-tui-core-9f2c4e1a7b3d5c60-412"])
        #expect(second.sent().isEmpty)
    }

    /// A daemon that replays many sites at every launch keeps its own slots and its own Sentry budget: the app's
    /// own blocking site found later is still kept and sent.
    @Test func aDaemonsManySitesLeaveTheAppsOwnSiteItsSampleAndItsEvent() throws {
        let launch = Self.launch(SavedState())
        for line in 0..<UInt32(12) {
            launch.sink.record(daemonSite: Self.sighting(try Self.fsSite(line: 100 + line)))
        }
        launch.sink.record(Self.appSite)

        let blocking = launch.collector.snapshot().blocking
        #expect(blocking.filter { $0.source == .daemon }.count == StallAggregate.maxDaemonSamples)
        #expect(blocking.filter { $0.source == .detector }.count == 1)
        let sent = launch.sent()
        #expect(sent.filter { $0.type.hasPrefix("Daemon") }.count == BlockingReportBudget.perLaunch)
        #expect(sent.filter { $0.type == "MainThreadBlocking" }.count == 1)

        let report = Self.builder.build(context: HangReportFixtures.context(), watchdog: launch.collector.drain(), metricKit: [])
        #expect(report.hangs.filter { $0.source == .detector }.count == 1)
        #expect(report.hangs.filter { $0.source == .daemon }.count == StallAggregate.maxDaemonSamples)
    }

    /// Lane items run at once: every admitted site and time is in the last save of each store.
    @Test func concurrentDaemonSitesSaveTheirLedgerAndTimesInOrder() throws {
        let saved = SavedState()
        let launch = Self.launch(saved)
        let sites = try (0..<UInt32(32)).map { Self.sighting(try Self.fsSite(line: 500 + $0)) }
        DispatchQueue.concurrentPerform(iterations: sites.count) { launch.sink.record(daemonSite: sites[$0]) }

        let last = try #require(saved.ledgers.last)
        #expect(last.lives.first?.sites.count == sites.count)
        #expect(saved.ledgers.map { $0.lives.first?.sites.count ?? 0 } == Array(1...sites.count))
        #expect(saved.savedDaemonTimes.map(\.count) == Array(1...BlockingReportBudget.perLaunch))
    }

    @Test func theLedgerRemembersAFewLivesAndBoundsEach() throws {
        var ledger = DaemonSiteLedger()
        let site = try Self.fsSite()
        for life in 0..<(DaemonSiteLedger.maxLives + 2) {
            let admitted = ledger.admit(Self.sighting(site, life: "life-\(life)"))
            #expect(admitted)
        }
        #expect(ledger.lives.map(\.life) == (2..<(DaemonSiteLedger.maxLives + 2)).map { "life-\($0)" })
        let readmitted = ledger.admit(Self.sighting(site, life: "life-\(DaemonSiteLedger.maxLives + 1)"))
        #expect(!readmitted)
        let decoded = try JSONDecoder().decode(DaemonSiteLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
    }

    /// A main-thread file read from the app's own binary.
    private static let appSite = BlockingViolation(kind: .fileIO, frames: [
        BlockingFrame(imageUUID: UUID(uuidString: HangReportFixtures.appUUID) ?? UUID(), offset: 0x300),
    ])
}
