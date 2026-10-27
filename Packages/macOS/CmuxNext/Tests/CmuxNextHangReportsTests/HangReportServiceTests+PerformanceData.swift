@testable import CmuxNextHangReports
import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing

/// Aggregate performance data (`diagnostics.performanceData`, p09-observability task 134): off by default, and a
/// Release report is schema 3's histograms and stability counts only, whatever the build recorded or queued before.
extension HangReportServiceTests {
    typealias CaptureJobs = HangReportFieldDataFlowTests.Jobs

    /// A schema-3 service of `channel` over `folder`, with the field sources `sources` and a collector that takes
    /// one `main.turn` black-box event at a long hang, its capture held in `jobs`.
    static func performanceDataService(_ transport: any HangReportTransport, folder: URL, sources: HangReportFieldSources,
                                       channel: String = "release", jobs: CaptureJobs = CaptureJobs(),
                                       aggregatesAllowed: Bool = true) -> HangReportService {
        let event = HangReportWireFormatTests.record("main.turn", phase: .begin, at: 1_000)
        let collector = HangReportCollector(resolve: { _ in [.other] }, captureBlackBox: { [event] }, keepsThreadHangs: true,
                                            schedule: { $0() }, scheduleCapture: { jobs.append($0) })
        return HangReportService(
            store: HangReportStore(directory: folder.appending(path: "reports")), transport: transport,
            builder: HangReportFixtures.builder(wireSchema: .v3),
            scanner: PrivacyLeakScanner(forbiddenTerms: HangReportFixtures.forbiddenTerms),
            identity: InstallIdentity(suiteName: "hang-reports-performance-\(UUID().uuidString)"), collector: collector,
            environment: HangReportService.Environment(
                app: HangReport.App(version: "0.70.0", build: "70123", channel: channel), os: HangReport.OS(version: "15.7.4"),
                hardware: HardwareClass(arch: "arm64", chip: "Apple M4 Pro", cores: 14, memoryGB: 48),
                counts: { CoarseCounts(windows: 1, workspaces: 3, panes: 4, tabs: 9) },
                aggregatesAllowed: { aggregatesAllowed }, fieldData: sources,
                features: { HangReport.FeatureState(hash: "0123456789abcdef", nonDefault: []) }))
    }

    static func performanceDataFolder() -> URL {
        FileManager().temporaryDirectory.appending(path: "hang-reports-performance-\(UUID().uuidString)")
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func performanceDataIsOffByDefault() async {
        let folder = Self.performanceDataFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Feature.performanceDataReports.defaults == FeatureDefaults(all: false))
        #expect(HangReportAskPolicy().performanceDataDecision(settingOn: false, consented: true) == .off)
        let (_, metrics) = HangReportWireFormatTests.metrics([.keyFrame(.terminal)])
        metrics.record(.keyFrame(.terminal), 2_500)
        let transport = RecordingTransport()
        let service = Self.performanceDataService(transport, folder: folder,
                                                  sources: HangReportFieldSources(runtime: metrics.runtime, metricsDirectory: nil))
        #expect(await service.mode == .off)
        await service.launched()
        await service.receive(HangReportFixtures.metricKitInput())
        #expect(transport.sent.isEmpty, "nothing goes before the person turns it on")
    }

    @Test func aReleaseReportHasOnlyHistogramsAndStabilityCounts() async throws {
        let folder = Self.performanceDataFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let metricsFolder = folder.appending(path: "metrics")
        _ = try HangReportFieldDataFlowTests().writeEarlierLaunch(to: metricsFolder)
        let (store, metrics) = HangReportWireFormatTests.metrics([.keyFrame(.terminal), .stabilityLaunch])
        let sources = HangReportFieldSources(runtime: metrics.runtime, metricsDirectory: metricsFolder)

        // An earlier launch with hang reports on saved a hang, a watched thread's hang and its black box for the next one.
        let jobs = CaptureJobs()
        let earlier = Self.performanceDataService(RecordingTransport(), folder: folder, sources: sources, jobs: jobs)
        await earlier.setMode(.full)
        earlier.collector.noteStall(durationNanos: 1_500_000_000, cpuNanos: 0, addresses: [1])
        earlier.collector.noteThreadHang(durationNanos: 3_000_000_000, addresses: [1],
                                         thread: HangSample.WatchedThread(name: "daemon-reader", kind: "lane"))
        let capture = try #require(jobs.scheduled.first)
        await capture()
        earlier.saveForNextLaunch()
        let reports = folder.appending(path: "reports")
        #expect(Self.exists(reports.appending(path: "pending.json")))
        #expect(Self.exists(reports.appending(path: "pending-blackbox.json")))

        metrics.record(.keyFrame(.terminal), 2_500)
        metrics.record(.stabilityLaunch, 1)
        let transport = RecordingTransport()
        let releaseJobs = CaptureJobs()
        let release = Self.performanceDataService(transport, folder: folder, sources: sources, jobs: releaseJobs)
        await release.setMode(.aggregates)
        release.collector.noteStall(durationNanos: 2_000_000_000, cpuNanos: 0, addresses: [1])
        #expect(releaseJobs.scheduled.isEmpty, "no black box is read in aggregates")
        await release.receive(HangReportFixtures.metricKitInput())
        await release.launched()

        #expect(transport.sent.count == 1)
        let body = try #require(transport.sent.first)
        #expect(HangReportServerRules.violations(in: body).isEmpty)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        for absent in ["blackbox", "launches", "input_latency", "input_latency_bucket_edges_ms", "scroll_jank", "active_seconds",
                       "features_hash", "features", "blocking_sites"] {
            #expect(json[absent] == nil, "\(absent) is not aggregate data")
        }
        for empty in ["hangs", "cpuExceptions", "stallHistogram", "intervals"] {
            #expect((json[empty] as? [Any])?.isEmpty == true, "\(empty) carries no sample")
        }
        let report = try JSONDecoder().decode(HangReport.self, from: body)
        #expect(report.schema == 3)
        #expect(report.app.channel == "release")
        #expect(report.metrics.isEmpty, "no MetricKit payload")
        #expect(report.isAggregatesOnly)
        #expect(report.histograms?.map(\.name) == ["key.frame.terminal"])
        #expect(report.stability?.launch == 1)
        #expect(report.launchSections?.first?.histograms.map(\.name) == ["launch.first_frame.cold"])
        #expect(Self.exists(release.lastReportURL), "View Hang Report shows the body sent")
        #expect(store.delta().isEmpty, "marked sent once the server took it")
        #expect(release.collector.snapshot().isEmpty, "no hang is recorded in aggregates")
        #expect(!Self.exists(reports.appending(path: "pending.json")), "what the earlier launch saved for a hang report is gone")
        #expect(!Self.exists(reports.appending(path: "pending-blackbox.json")))
    }

    @Test func aHangReportQueuedBeforeNeverGoesAsAggregates() async throws {
        let folder = Self.performanceDataFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, metrics) = HangReportWireFormatTests.metrics([.keyFrame(.terminal)])
        let sources = HangReportFieldSources(runtime: metrics.runtime, metricsDirectory: nil)
        let offline = RecordingTransport([.retryLater])
        let full = Self.performanceDataService(offline, folder: folder, sources: sources)
        await full.setMode(.full)
        full.collector.noteStall(durationNanos: 1_500_000_000, cpuNanos: 0, addresses: [1])
        await full.receive(HangReportFixtures.metricKitInput())
        #expect(offline.sent.count == 1, "queued with its hangs; the server did not take it")

        let online = RecordingTransport()
        let aggregates = Self.performanceDataService(online, folder: folder, sources: sources)
        await aggregates.setMode(.aggregates)
        await aggregates.launched()
        #expect(online.sent.isEmpty, "the queued hang report is dropped, never sent")
    }

    @Test func aggregatesKeepThisLaunchsSamplesAtQuitAndStopWhenNotAllowed() async {
        let folder = Self.performanceDataFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (store, metrics) = HangReportWireFormatTests.metrics([.keyFrame(.terminal)])
        let sources = HangReportFieldSources(runtime: metrics.runtime, metricsDirectory: nil)
        let service = Self.performanceDataService(RecordingTransport(), folder: folder, sources: sources)
        await service.setMode(.aggregates)
        metrics.record(.keyFrame(.terminal), 2_500)
        service.saveForNextLaunch()
        #expect(!store.delta().isEmpty, "the next launch's report carries them")

        let transport = RecordingTransport()
        let refused = Self.performanceDataService(transport, folder: folder, sources: sources, aggregatesAllowed: false)
        await refused.setMode(.aggregates)
        await refused.launched()
        #expect(transport.sent.isEmpty)
        #expect(await refused.mode == .off, "a managed block or a removed consent turns it off")
    }
}
