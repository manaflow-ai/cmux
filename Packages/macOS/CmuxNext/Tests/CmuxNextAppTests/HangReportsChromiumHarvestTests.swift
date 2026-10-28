@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextControl
import CmuxNextHangReports
import CmuxNextMetrics
import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Testing

/// Task 107: every hang report trigger harvests Chromium's histograms before the service reads the store, so the
/// report carries `chromium.*`; a harvest that never answers delays the report only by the harvest limit; and the
/// harvest's tally shows in `debug.shipping_mode`.
@MainActor @Suite struct HangReportsChromiumHarvestTests {
    /// How often a test's harvest ran.
    final class HarvestCount: Sendable {
        let count = Mutex(0)
    }

    /// A transport that keeps every report for later (nothing leaves the test).
    struct KeptTransport: HangReportTransport {
        func send(_ body: Data) async -> HangReportTransportResult { .retryLater }
    }

    private let folder = FileManager.default.temporaryDirectory.appending(path: "hang-chromium-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A runtime whose metrics go to a fresh store, and that store.
    private static func recordingRuntime() -> (TraceRuntime, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "7", channel: "nightly", osVersion: "26.0", hardwareClass: "Mac16,10",
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 28))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242, catalog: [.mainTurn])
        #expect(store.attach(to: runtime))
        return (runtime, store)
    }

    /// A schema 3 service whose field data is `runtime`'s store, turned on.
    private func service(_ runtime: TraceRuntime) async -> HangReportService {
        let service = HangReportService(
            store: HangReportStore(directory: folder.appending(path: "reports")), transport: KeptTransport(),
            builder: HangReportBuilder(classifier: ImageClassifier(appBundlePath: "/Applications/cmux NEXT.app", forbiddenTerms: [],
                                                                   systemImageExists: { _ in false }),
                                       resolver: DyldImageResolver(), wireSchema: .v3),
            scanner: PrivacyLeakScanner(forbiddenTerms: []), identity: InstallIdentity(suiteName: "hang-chromium-\(UUID().uuidString)"),
            collector: HangReportCollector(resolve: { _ in [] }, schedule: { $0() }),
            environment: HangReportService.Environment(
                app: HangReport.App(version: "1.0", build: "7", channel: "nightly"), os: HangReport.OS(version: "26.0"),
                hardware: HardwareClass(arch: "arm64", chip: "Apple M4 Pro", cores: 14, memoryGB: 48),
                counts: { CoarseCounts(windows: 1, workspaces: 1, panes: 1, tabs: 1) },
                fieldData: HangReportFieldSources(runtime: runtime, metricsDirectory: nil)))
        await service.setEnabled(true)
        return service
    }

    private func controller(_ service: HangReportService, harvest: MetricsHarvest, limit: Duration = ControlRouter.metricsHarvestLimit)
        -> HangReportsController {
        let suite = "hang-chromium-\(UUID().uuidString)"
        return HangReportsController(service: service, managedDisables: { false }, defaults: UserDefaults(suiteName: suite) ?? .standard,
                                     chromiumHistograms: harvest, chromiumHarvestLimit: limit,
                                     work: BackgroundWork(label: "test.hang-chromium"), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    @Test func viewHangReportHarvestsChromiumOnceBeforeTheReportReadsTheStore() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (runtime, store) = Self.recordingRuntime()
        Metrics(runtime: runtime).record(.mainTurn, 1_000)
        let harvests = HarvestCount()
        let harvest = MetricsHarvest(name: "chromium", run: {
            harvests.count.withLock { $0 += 1 }
            store.foldChromium(.keyPressedLatency, count: 2, sum: 30_000, buckets: [.init(minimum: 12_000, count: 2)])
        }, tally: { ["folded": 1] })
        let controller = controller(await service(runtime), harvest: harvest)

        let url = try #require(await controller.viewableReport())
        #expect(harvests.count.withLock { $0 } == 1)
        let report = try String(contentsOf: url, encoding: .utf8)
        #expect(report.contains("chromium.EventLatency.KeyPressed.TotalLatency"), "the harvest ran before the report read the store")
        #expect(report.contains("main.turn"))
    }

    @Test func aHarvestThatNeverAnswersDelaysTheReportOnlyByItsLimit() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (runtime, _) = Self.recordingRuntime()
        Metrics(runtime: runtime).record(.mainTurn, 1_000)
        let (never, release) = AsyncStream.makeStream(of: Void.self)
        // Ignores the trigger's cancellation, as a stalled Chromium UI thread does.
        let hung = Task { for await _ in never {} }
        defer { release.finish() }
        let harvest = MetricsHarvest(name: "chromium", run: { await hung.value }, tally: { [:] })
        let controller = controller(await service(runtime), harvest: harvest, limit: .milliseconds(50))

        let started = ContinuousClock.now
        let url = try #require(await controller.viewableReport())
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("main.turn"))
    }

    @Test func anUnsupportedChromiumShowsInShippingMode() async {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (runtime, _) = Self.recordingRuntime()
        let harvest = MetricsHarvest(name: "chromium", run: {}, tally: { ["folded": 0, "unsupported": 3] })
        let controller = controller(await service(runtime), harvest: harvest)
        let state = await controller.shippingModeState(setting: true)
        #expect(state.chromiumHistograms?["unsupported"] == 3)

        let suite = "hang-chromium-\(UUID().uuidString)"
        let without = HangReportsController(service: nil, managedDisables: { false }, defaults: UserDefaults(suiteName: suite) ?? .standard,
                                            work: BackgroundWork(label: "test.hang-chromium"), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        #expect(await without.shippingModeState(setting: nil).chromiumHistograms == nil)
    }
}
