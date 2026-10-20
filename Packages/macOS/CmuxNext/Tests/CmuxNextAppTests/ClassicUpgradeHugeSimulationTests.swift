import AppKit
@testable import CmuxNextApp
import CmuxNextOnboarding
import Foundation
import Testing

/// The largest classic sessions: 512 workspaces in 4 windows with 30 groups.
@MainActor @Suite(.serialized, .timeLimit(.minutes(10)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicUpgradeHugeSimulationTests {
    @Test func aHugeSessionComesOverOnceWithTheFirstWindowFirst() async throws {
        let profile = ClassicUpgradeProfile.huge
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        let launch = await sim.launch()
        print(String(format: "CLASSIC-SIM huge workspaces=%d first_window=%.2fs migration=%.2fs per_workspace=%.0fms",
                     profile.expectedCount, launch.firstWindow.simSeconds, launch.migration.simSeconds,
                     launch.migration.simSeconds * 1000 / Double(profile.expectedCount)))
        #expect(launch.failure == nil, "\(String(describing: launch.failure))")
        if let outcome = launch.outcome {
            print("CLASSIC-SIM huge opened=\(outcome.opened.count) failed=\(outcome.failures.count) first=\(outcome.failures.values.first ?? "-")")
        }
        #expect(launch.firstWindow < ClassicUpgradeSimulationTests.firstWindowBudget, "first window after \(launch.firstWindow)")
        #expect(launch.migration < .seconds(150), "migration took \(launch.migration)")
        await sim.settle()
        try sim.verify(profile, classicBefore: before)
        let clock = ContinuousClock()
        let start = clock.now
        let again = try await sim.relaunch()
        let relaunch = clock.now - start
        print(String(format: "CLASSIC-SIM huge-relaunch decision=%@ took=%.2fs", String(describing: again.decision), relaunch.simSeconds))
        #expect(again.opened.isEmpty && relaunch < .seconds(2), "\(again) in \(relaunch)")
        await sim.shutdown()
    }
}
