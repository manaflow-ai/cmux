@testable import CmuxNextHangReports
import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Testing

/// Schema 3's field data end to end: the collector takes the black box once per report
/// at a long hang or a slow key frame, and the service sends this launch's delta and an earlier launch's section,
/// marks them sent once the server took the report, and deletes the earlier launch's file then.
struct HangReportFieldDataFlowTests {
    typealias Job = @Sendable () async -> Void

    /// The capture jobs a collector scheduled, run by the test.
    final class Jobs: Sendable {
        private let jobs = Mutex<[Job]>([])

        func append(_ job: @escaping Job) { jobs.withLock { $0.append(job) } }
        var scheduled: [Job] { jobs.withLock { $0 } }
    }

    static let event = HangReportWireFormatTests.record("main.turn", phase: .begin, at: 1_000)

    @Test func aLongHangOrASlowKeyFrameTakesTheBlackBoxOncePerReport() async {
        let jobs = Jobs()
        let collector = HangReportCollector(resolve: { _ in [] }, captureBlackBox: { [Self.event] }, schedule: { $0() },
                                            scheduleCapture: { jobs.append($0) })
        func scheduled() -> [Job] { jobs.scheduled }

        collector.noteKeyFrame(durationMicros: 80_000)
        #expect(scheduled().isEmpty, "off: nothing is read")
        collector.setEnabled(true)
        collector.noteKeyFrame(durationMicros: HangReportCollector.blackBoxKeyFrameMicros)
        collector.noteHang(durationNanos: 999_000_000, addresses: [])
        #expect(scheduled().isEmpty, "a 50 ms key frame and a hang under 1 s take none")

        collector.noteHang(durationNanos: 1_500_000_000, addresses: [])
        collector.noteKeyFrame(durationMicros: 80_000)
        #expect(scheduled().count == 1, "a capture running takes no second one")
        await scheduled()[0]()
        collector.noteKeyFrame(durationMicros: 80_000)
        #expect(scheduled().count == 1, "one held until the report takes it")
        #expect(collector.blackBoxSnapshot() == [Self.event])
        #expect(collector.takeBlackBox() == [Self.event])
        #expect(collector.takeBlackBox().isEmpty)

        collector.noteKeyFrame(durationMicros: 80_000)
        #expect(scheduled().count == 2)
        collector.setEnabled(false)
        await scheduled()[1]()
        #expect(collector.blackBoxSnapshot().isEmpty, "turned off while it read: not kept")
    }

    @Test func aHangOfASecondThatEndedTakesTheBlackBox() async {
        let jobs = Jobs()
        let collector = HangReportCollector(resolve: { _ in [] }, captureBlackBox: { [Self.event] }, schedule: { $0() },
                                            scheduleCapture: { jobs.append($0) })
        collector.setEnabled(true)
        collector.noteStall(durationNanos: 999_000_000, cpuNanos: 0, addresses: [1])
        #expect(jobs.scheduled.isEmpty, "a stall under 1 s takes none")
        // The watchdog's onHang fires only at 2 s, at most once per 5 minutes; every hang ends in noteStall.
        collector.noteStall(durationNanos: 1_500_000_000, cpuNanos: 0, addresses: [1])
        #expect(jobs.scheduled.count == 1)
        await jobs.scheduled[0]()
        #expect(collector.blackBoxSnapshot() == [Self.event])

        // A report queued with an older snapshot does not release a newer black box.
        collector.releaseBlackBox(sent: [])
        #expect(collector.blackBoxSnapshot() == [Self.event])
        collector.releaseBlackBox(sent: [Self.event])
        #expect(collector.blackBoxSnapshot().isEmpty)
        collector.noteStall(durationNanos: 1_500_000_000, cpuNanos: 0, addresses: [1])
        #expect(jobs.scheduled.count == 2, "released: the next hang takes a new one")
    }

    @Test func aCollectorWithoutACaptureTakesNone() {
        let jobs = Jobs()
        let collector = HangReportCollector(resolve: { _ in [] }, schedule: { $0() }, scheduleCapture: { jobs.append($0) })
        collector.setEnabled(true)
        collector.noteHang(durationNanos: 5_000_000_000, addresses: [])
        #expect(jobs.scheduled.isEmpty)
    }

    private let directory = FileManager().temporaryDirectory.appending(path: "hang-reports-field-\(UUID().uuidString)")

    func service(_ transport: any HangReportTransport, sources: HangReportFieldSources, wireSchema: HangReport.WireSchema = .v3,
                 version: String = "0.70.0", collector: HangReportCollector? = nil) -> HangReportService {
        let suite = "hang-reports-field-\(UUID().uuidString)"
        return HangReportService(
            store: HangReportStore(directory: directory.appending(path: "reports")), transport: transport,
            builder: HangReportFixtures.builder(wireSchema: wireSchema),
            scanner: PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms),
            identity: InstallIdentity(suiteName: suite),
            collector: collector ?? HangReportCollector(resolve: { _ in [.other] }, schedule: { $0() }),
            environment: HangReportService.Environment(
                app: HangReport.App(version: version, build: "70123", channel: "nightly"), os: HangReport.OS(version: "15.7.4"),
                hardware: HardwareClass(arch: "arm64", chip: "Apple M4 Pro", cores: 14, memoryGB: 48),
                counts: { CoarseCounts(windows: 1, workspaces: 3, panes: 4, tabs: 9) }, fieldData: sources))
    }

    /// An earlier launch's file in `metrics`, with a cold first frame and its launch count.
    func writeEarlierLaunch(to metrics: URL) throws -> URL {
        var profile = HangReportWireFormatTests.metricsProfile
        profile.appVersion = "0.69.0"
        let runtime = TraceRuntime(role: .app)
        let earlier = MetricsStore(role: .app, profile: profile, pid: 1_111, catalog: [.launchFirstFrame(.cold), .stabilityLaunch])
        earlier.attach(to: runtime)
        Metrics(runtime: runtime).record(.launchFirstFrame(.cold), 420)
        Metrics(runtime: runtime).record(.stabilityLaunch, 1)
        let path = try #require(earlier.adoptFile(directory: metrics.path(percentEncoded: false)))
        return URL(filePath: path)
    }

    @Test func aReportSendsTheDeltaAndAnEarlierLaunchAndMarksThemSent() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let metricsFolder = directory.appending(path: "metrics")
        let earlierFile = try writeEarlierLaunch(to: metricsFolder)
        let (store, metrics) = HangReportWireFormatTests.metrics([.keyFrame(.terminal), .stabilityLaunch])
        metrics.record(.keyFrame(.terminal), 2_500)
        metrics.record(.stabilityLaunch, 1)
        let sources = HangReportFieldSources(runtime: metrics.runtime, metricsDirectory: metricsFolder)
        let transport = HangReportServiceTests.RecordingTransport()
        let service = service(transport, sources: sources)

        await service.setEnabled(true)
        await service.launched()

        let body = try #require(transport.sent.first)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        let report = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(report.schema == 3)
        #expect(report.histograms?.map(\.name) == ["key.frame.terminal"])
        #expect(report.histograms?.first?.count == 1)
        #expect(report.stability?.launch == 1)
        let section = try #require(report.launchSections?.first)
        #expect(section.profile.version == "0.69.0")
        #expect(section.histograms.map(\.name) == ["launch.first_frame.cold"])
        #expect(section.stability?.launch == 1)
        #expect(ImageClassifier.isUUID(section.id))

        #expect(store.delta().isEmpty, "the sent report's samples are marked sent")
        #expect(!FileManager.default.fileExists(atPath: earlierFile.path(percentEncoded: false)), "the section's file is deleted")
        #expect(await sources.earlierLaunches().isEmpty)

        // Turned off and on while running: what was recorded meanwhile is never sent.
        metrics.record(.keyFrame(.terminal), 3_000)
        await service.setEnabled(false)
        metrics.record(.keyFrame(.terminal), 3_100)
        await service.setEnabled(true)
        #expect(store.delta().isEmpty)
    }

    @Test func aSchemaTwoServiceReadsNoFieldData() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let metricsFolder = directory.appending(path: "metrics")
        let earlierFile = try writeEarlierLaunch(to: metricsFolder)
        let (store, metrics) = HangReportWireFormatTests.metrics([.keyFrame(.terminal)])
        metrics.record(.keyFrame(.terminal), 2_500)
        let sources = HangReportFieldSources(runtime: metrics.runtime, metricsDirectory: metricsFolder)
        let transport = HangReportServiceTests.RecordingTransport()
        let service = service(transport, sources: sources, wireSchema: .v2)

        await service.setEnabled(true)
        await service.launched()

        #expect(transport.sent.isEmpty)
        #expect(!store.delta().isEmpty)
        #expect(FileManager.default.fileExists(atPath: earlierFile.path(percentEncoded: false)))
    }

    @Test func aQueuedReportTheOutboxDropsUnsentKeepsItsFieldData() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let metricsFolder = directory.appending(path: "metrics")
        let earlierFile = try writeEarlierLaunch(to: metricsFolder)
        let (store, metrics) = HangReportWireFormatTests.metrics([.keyFrame(.terminal), .stabilityLaunch])
        metrics.record(.keyFrame(.terminal), 2_500)
        let sources = HangReportFieldSources(runtime: metrics.runtime, metricsDirectory: metricsFolder)
        let offline = HangReportServiceTests.RecordingTransport([.retryLater])
        let first = service(offline, sources: sources)

        await first.setEnabled(true)
        await first.launched()
        #expect(offline.sent.count == 1, "queued; the server did not take it")
        #expect(FileManager.default.fileExists(atPath: earlierFile.path(percentEncoded: false)), "kept until the server takes it")
        #expect(!store.delta().isEmpty, "not marked sent while only queued")

        // The nightly updated: the next launch drops the queued body unsent, and its field data goes again.
        let online = HangReportServiceTests.RecordingTransport()
        let updated = service(online, sources: sources, version: "0.71.0")
        await updated.setEnabled(true)
        await updated.launched()

        #expect(online.sent.count == 1, "the old body is dropped, never sent")
        let report = try JSONDecoder().decode(HangReport.self, from: try #require(online.sent.first))
        #expect(report.app.version == "0.71.0")
        #expect(report.histograms?.map(\.name) == ["key.frame.terminal"])
        #expect(report.launchSections?.first?.profile.version == "0.69.0")
        #expect(store.delta().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: earlierFile.path(percentEncoded: false)))
    }

    @Test func aBlackBoxTakenBeforeQuitGoesInTheNextLaunchsReport() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, metrics) = HangReportWireFormatTests.metrics([.keyFrame(.terminal)])
        let sources = HangReportFieldSources(runtime: metrics.runtime, metricsDirectory: nil)
        let transport = HangReportServiceTests.RecordingTransport()
        let jobs = Jobs()
        let first = service(transport, sources: sources, collector: HangReportCollector(
            resolve: { _ in [.other] }, captureBlackBox: { [Self.event] }, schedule: { $0() }, scheduleCapture: { jobs.append($0) }))
        await first.setEnabled(true)
        first.collector.noteStall(durationNanos: 1_500_000_000, cpuNanos: 0, addresses: [1])
        let capture = try #require(jobs.scheduled.first)
        await capture()
        first.saveForNextLaunch()
        #expect(transport.sent.isEmpty, "no report before the quit")

        let next = service(transport, sources: sources, collector: HangReportCollector(
            resolve: { _ in [.other] }, captureBlackBox: { [] }, schedule: { $0() }, scheduleCapture: { jobs.append($0) }))
        await next.setEnabled(true)
        await next.launched()

        let report = try JSONDecoder().decode(HangReport.self, from: try #require(transport.sent.first))
        #expect(report.hangs.map(\.durationMs) == [1_500])
        #expect(report.blackbox?.map(\.name) == ["main.turn"])
        #expect(next.collector.blackBoxSnapshot().isEmpty, "released once the report is queued")
    }

    /// A ring file of process `role` with one `name` record, written where that process writes it.
    static func writeRing(_ role: TraceRuntime.Role, pid: UInt32, name: StaticString, to folder: URL) throws {
        let daemonBit = UInt8(6)
        let blackBox = TraceBlackBox(role: role, directory: folder.path(percentEncoded: false), runtime: TraceRuntime(role: role),
                                     process: TraceBlackBox.ProcessFacts(pid: pid),
                                     catalog: TraceRing.nameTable(names: [(id: 1, category: daemonBit, text: name)],
                                                                  categories: [(bit: daemonBit, text: "daemon")]))
        blackBox.ring.write(name: 1, phase: .instant, timestamp: 1_000 + UInt64(pid), arg0: 7)
        _ = try #require(blackBox.adoptFile())
    }

    @Test func theBlackBoxMergesTheDaemonAndHolderRingsWhereTheyWriteThem() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // The daemon's ring is in its CMUX_TRACE_FLOWS folder, a holder's in `<socket>.trace` beside its socket.
        let flows = directory.appending(path: "flows")
        let holderSockets = directory.appending(path: "cmux-hd-501")
        try Self.writeRing(.daemon, pid: 2_002, name: "daemon.request", to: flows)
        try Self.writeRing(.holder, pid: 3_003, name: "holder.spawn", to: holderSockets.appending(path: "0123456789abcdef.trace"))
        let sources = HangReportFieldSources(runtime: TraceRuntime(role: .app), metricsDirectory: nil,
                                             rings: .init(directories: [flows], holderSockets: holderSockets),
                                             isAlive: { _, _ in true })

        let records = await sources.captureBlackBox()
        #expect(records.map(\.process) == [.daemon, .holder])
        #expect(records.map { $0.name?.text } == ["daemon.request", "holder.spawn"])
        let events = HangReportBuilder.blackboxEvents(records)
        #expect(events.map(\.process) == ["daemon", "holder"])

        let gone = HangReportFieldSources(runtime: TraceRuntime(role: .app), metricsDirectory: nil,
                                          rings: .init(directories: [flows], holderSockets: holderSockets),
                                          isAlive: { _, _ in false })
        #expect(await gone.captureBlackBox().isEmpty, "a dead process's ring is not merged")
    }

    @Test func theAppFactoryReadsTheMetricsFolderAndTheRingsWhereTheyAre() throws {
        let bundleID = Bundle.main.bundleIdentifier
        let service = HangReportService.forThisApp(
            folder: directory, endpoint: "http://127.0.0.1:9/hang-reports", channel: "nightly", personalTerms: [],
            counts: { .unknown }, stillAllowed: { false }, mainThreadHistograms: { nil }, wireSchema: .v3)
        let sources = try #require(service.fieldSources)
        #expect(sources.metricsDirectory == HangReportFieldSources.appMetricsDirectory(bundleID: bundleID))
        #expect(sources.rings.directories.first == TraceBlackBoxFileSteps.appDirectory(bundleID: bundleID))
        #expect(sources.rings.holderSockets == HangReportFieldSources.RingFolders.holderSocketDirectory())

        let flows = URL(filePath: "/tmp/flows", directoryHint: .isDirectory)
        #expect(HangReportFieldSources.RingFolders.app(bundleID: bundleID, flowsDirectory: flows).directories.last == flows)
    }
}
