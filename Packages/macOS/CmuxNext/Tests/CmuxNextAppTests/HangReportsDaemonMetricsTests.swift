@testable import CmuxNextApp
import CmuxNextMetrics
import CmuxNextWakeups
import Foundation
import Testing

/// Task 062: the hang reports controller's daemon metrics fold reaches `debug.shipping_mode`, so a report whose
/// daemon had no metrics file does not look like a daemon that served no requests.
@MainActor @Suite struct HangReportsDaemonMetricsTests {
    @Test func aMissingDaemonMetricsFileShowsInShippingMode() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hang-daemon-metrics-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "cn-hang-daemon-metrics-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fold = DaemonMetricsFold(reader: ChildMetricsReader(role: .daemon, directory: folder, isRunning: { _ in true }),
                                     metrics: Metrics(), work: BackgroundWork(label: "test.daemon-metrics"))
        let work = BackgroundWork(label: "test.hang-reports"), mainWork = MainWorkScheduler(budget: MainFrameBudget())
        let controller = HangReportsController(service: nil, managedDisables: { false }, defaults: defaults,
                                               daemonMetrics: fold, daemonPID: { 4_711 }, work: work, mainWork: mainWork)

        #expect(await fold.fold(pid: 4_711) == .missing)
        let state = await controller.shippingModeState(setting: nil)
        #expect(state.daemonMetricsFold?["missing"] == 1)
        #expect(state.daemonMetricsFold?["folded"] == 0)

        let without = HangReportsController(service: nil, managedDisables: { false }, defaults: defaults, work: work, mainWork: mainWork)
        #expect(await without.shippingModeState(setting: nil).daemonMetricsFold == nil)
    }
}
