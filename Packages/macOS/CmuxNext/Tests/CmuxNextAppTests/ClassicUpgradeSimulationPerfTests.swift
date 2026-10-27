import AppKit
@testable import CmuxNextApp
import CmuxNextOnboarding
import Foundation
import Testing

/// Opt-in fleet measurements for the classic upgrade simulation. The functional
/// simulation deliberately checks only migration behavior; this harness keeps
/// launch timing visible without turning host load into a PR failure.
@MainActor @Suite(.serialized, .timeLimit(.minutes(15)),
                  .enabled(if: ProcessInfo.processInfo.environment["CMUX_CLASSIC_UPGRADE_PERF"] == "1"
                               && SameTreeDaemonBinary.url != nil,
                           "set CMUX_CLASSIC_UPGRADE_PERF=1 on a fleet run"))
struct ClassicUpgradeSimulationPerfTests {
    @Test(arguments: ClassicUpgradeProfile.matrix.map(\.name))
    func matrixReportsLaunchTimings(_ name: String) async throws {
        let profile = try #require(ClassicUpgradeProfile.matrix.first { $0.name == name })
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let sim = try ClassicUpgradeSimulator(mac: mac)
        let launch = await sim.launch()
        print(String(format: "CLASSIC-SIM-PERF %@ workspaces=%d first_window=%.2fs migration=%.2fs per_workspace=%.0fms",
                     name, profile.expectedCount, launch.firstWindow.simSeconds, launch.migration.simSeconds,
                     profile.expectedCount == 0 ? 0 : launch.migration.simSeconds * 1000 / Double(profile.expectedCount)))
        #expect(launch.failure == nil, "\(String(describing: launch.failure))")
        #expect(launch.outcome?.decision == .firstRun, "\(String(describing: launch.outcome))")
        await sim.shutdown()
    }
}
