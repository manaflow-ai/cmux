import AppKit
@testable import CmuxNextApp
import CmuxNextOnboarding
import Foundation
import Testing

/// Opt-in fleet measurements for the classic upgrade simulation. The functional
/// simulation deliberately checks only migration behavior; this harness keeps
/// launch timing visible without turning host load into a PR failure.
@MainActor @Suite(.serialized, .ownsSidebarDocStore, .timeLimit(.minutes(15)),
                  .enabled(if: ProcessInfo.processInfo.environment["CMUX_CLASSIC_UPGRADE_PERF"] == "1"
                               && SameTreeDaemonBinary.url != nil,
                           "set CMUX_CLASSIC_UPGRADE_PERF=1 on a fleet run"))
struct ClassicUpgradeSimulationPerfTests {
    @Test(arguments: ["fresh", "small", "manyGroups", "nestedSplits", "browsersAndViewers", "multiWindow", "oldSchema", "messy"])
    func matrixReportsLaunchTimings(_ name: String) async throws {
        let profile = try #require(ClassicUpgradeProfile.matrix.first { $0.name == name })
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        BenchSpans.begin()
        let launch = await sim.launch()
        Self.reportDocumentWaits(name, BenchSpans.end())
        print(String(format: "CLASSIC-SIM-PERF %@ workspaces=%d first_window=%.2fs migration=%.2fs per_workspace=%.0fms",
                     name, profile.expectedCount, launch.firstWindow.simSeconds, launch.migration.simSeconds,
                     profile.expectedCount == 0 ? 0 : launch.migration.simSeconds * 1000 / Double(profile.expectedCount)))
        #expect(launch.failure == nil, "\(String(describing: launch.failure))")
        #expect(launch.outcome?.decision == .firstRun, "\(String(describing: launch.outcome))")
        #expect(launch.outcome?.failures.isEmpty == true, "\(String(describing: launch.outcome))")
        #expect(launch.outcome?.opened.count == profile.expectedCount, "\(String(describing: launch.outcome))")
        await sim.settle()
        do {
            try sim.verify(profile, classicBefore: before)
        } catch {
            await sim.shutdown()
            throw error
        }
        await sim.shutdown()
    }

    /// The import's wait for the sidebar document's reply before each group write (#28425), per
    /// imported workspace: count, sum and p50/p95/max in ms. A p95 above a frame (16 ms) asks for
    /// one settle per import batch instead.
    private static func reportDocumentWaits(_ name: String, _ spans: [BenchSpans.Span]) {
        let waits = spans.filter { $0.name == AppOnboardingServices.documentSettledSpan }.map(\.milliseconds).sorted()
        let at = { (share: Double) -> Double in waits.isEmpty ? 0 : waits[min(waits.count - 1, Int((share * Double(waits.count)).rounded(.up)) - 1)] }
        print(String(format: "CLASSIC-SIM-PERF-SETTLE %@ n=%d sum=%.2fms p50=%.2fms p95=%.2fms max=%.2fms", name, waits.count,
                     waits.reduce(0, +), at(0.5), at(0.95), waits.last ?? 0))
    }
}
