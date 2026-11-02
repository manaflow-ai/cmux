import AppKit
@testable import CmuxNextApp
import CmuxNextOnboarding
import Foundation
import Testing

/// The largest classic sessions: 512 workspaces in 4 windows (classic's cap
/// of 128 a window) with 30 groups, end to end on the real daemon.
///
/// The run takes minutes, longer than the suite watchdog allows one test
/// (180 s without a test finishing), so it is one simulation in phases, in
/// order: the launch and the first part of the run, then waiting for the
/// rest, then the checks and a relaunch.
@MainActor @Suite(.serialized, .timeLimit(.minutes(15)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicUpgradeHugeSimulationTests {
    /// The simulation every phase works on.
    private final class Run {
        let mac: ClassicUpgradeSimulator.Mac
        let sim: ClassicUpgradeSimulator
        let before: [String: String]
        var outcome: ClassicMigrationOutcome?
        var finished = false

        init() throws {
            mac = try ClassicUpgradeSimulator.Mac()
            try mac.save(ClassicUpgradeProfile.huge)
            before = try mac.classicDigest()
            sim = try ClassicUpgradeSimulator(mac: mac)
        }
    }

    private static var run: Run?

    /// Phases: 0 launches and runs up to 150 s, 1 to 4 wait up to 150 s more each, 5 checks.
    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func aHugeSessionComesOverOnceWithTheFirstWindowFirst(_ phase: Int) async throws {
        let profile = ClassicUpgradeProfile.huge
        switch phase {
        case 0:
            let run = try Run()
            Self.run = run
            let launch = await run.sim.launch(deadline: .seconds(150))
            run.outcome = launch.outcome
            if case .overBudget? = launch.failure as? ClassicUpgradeSimulator.SimulationFailure {} else { run.finished = true }
            print(String(format: "CLASSIC-SIM huge workspaces=%d first_window=%.2fs phase0=%.2fs made=%d",
                         profile.expectedCount, launch.firstWindow.simSeconds, launch.migration.simSeconds, run.sim.made().count))
            #expect(launch.firstWindow < ClassicUpgradeSimulationTests.firstWindowBudget, "first window after \(launch.firstWindow)")
        case 1...4:
            let run = try #require(Self.run)
            guard !run.finished, let task = run.sim.services.onboarding.classicMigrationRun else { return }
            if let outcome = await run.sim.wait(for: task, upTo: .seconds(150)) {
                run.outcome = outcome
                run.finished = true
            }
            print("CLASSIC-SIM huge phase\(phase) made=\(run.sim.made().count) finished=\(run.finished)")
        default:
            let run = try #require(Self.run)
            defer { Self.run = nil }
            if !run.finished, let task = run.sim.services.onboarding.classicMigrationRun {
                run.outcome = await run.sim.wait(for: task, upTo: .seconds(150))
            }
            let outcome = try #require(run.outcome, "the migration of 512 workspaces did not finish in 15 minutes (\(run.sim.made().count) made)")
            print("CLASSIC-SIM huge opened=\(outcome.opened.count) failed=\(outcome.failures.count) first=\(outcome.failures.values.first ?? "-")")
            print("CLASSIC-SIM huge \(run.sim.perWorkspaceReport())")
            // macOS hands out at most kern.tty.ptmx_max (511) PTYs, shared with every process:
            // background workspaces come over parked, so none runs out.
            let ptys = outcome.failures.values.filter { $0.contains("PTY capacity exhausted") }
            #expect(ptys.isEmpty, "\(ptys.count) workspaces found no free PTY")
            #expect(outcome.failures.isEmpty, "\(outcome.failures.values.prefix(3))")
            await run.sim.settle()
            try run.sim.verify(profile, classicBefore: run.before)
            let clock = ContinuousClock()
            let start = clock.now
            let again = try await run.sim.relaunch()
            let relaunch = clock.now - start
            print(String(format: "CLASSIC-SIM huge-relaunch decision=%@ took=%.2fs", String(describing: again.decision), relaunch.simSeconds))
            #expect(again.opened.isEmpty && relaunch < .seconds(2), "\(again) in \(relaunch)")
            await run.sim.shutdown()
        }
    }
}
