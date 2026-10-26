@testable import CmuxNextHangReports
import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing

/// Schema 3's field data end to end (p09-observability-063): the collector takes the black box once per report
/// at a long hang or a slow key frame, and the service sends this launch's delta and an earlier launch's section,
/// marks them sent once the report is queued, and deletes the earlier launch's file.
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

    @Test func aCollectorWithoutACaptureTakesNone() {
        let jobs = Jobs()
        let collector = HangReportCollector(resolve: { _ in [] }, schedule: { $0() }, scheduleCapture: { jobs.append($0) })
        collector.setEnabled(true)
        collector.noteHang(durationNanos: 5_000_000_000, addresses: [])
        #expect(jobs.scheduled.isEmpty)
    }

    private let directory = FileManager().temporaryDirectory.appending(path: "hang-reports-field-\(UUID().uuidString)")

    func service(_ transport: any HangReportTransport, sources: HangReportFieldSources, wireSchema: HangReport.WireSchema = .v3)
        -> HangReportService {
        let suite = "hang-reports-field-\(UUID().uuidString)"
        return HangReportService(
            store: HangReportStore(directory: directory.appending(path: "reports")), transport: transport,
            builder: HangReportFixtures.builder(wireSchema: wireSchema),
            scanner: PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms),
            identity: InstallIdentity(suiteName: suite), collector: HangReportCollector(resolve: { _ in [.other] }, schedule: { $0() }),
            environment: HangReportService.Environment(
                app: HangReport.App(version: "0.70.0", build: "70123", channel: "nightly"), os: HangReport.OS(version: "15.7.4"),
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
        let sources = HangReportFieldSources(runtime: metrics.runtime, metricsDirectory: metricsFolder, ringDirectory: nil)
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

        #expect(store.delta().isEmpty, "the queued report's samples are marked sent")
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
        let sources = HangReportFieldSources(runtime: metrics.runtime, metricsDirectory: metricsFolder, ringDirectory: nil)
        let transport = HangReportServiceTests.RecordingTransport()
        let service = service(transport, sources: sources, wireSchema: .v2)

        await service.setEnabled(true)
        await service.launched()

        #expect(transport.sent.isEmpty)
        #expect(!store.delta().isEmpty)
        #expect(FileManager.default.fileExists(atPath: earlierFile.path(percentEncoded: false)))
    }
}
