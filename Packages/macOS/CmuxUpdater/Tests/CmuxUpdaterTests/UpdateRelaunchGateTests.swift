import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Host double that reports whatever blockers the test sets.
@MainActor
private final class BlockerHost: UpdateActionDelegate {
    var blockers = UpdateRelaunchBlockers.none

    func updaterRequestsRetryCheckForUpdates() {}
    func updaterWillRelaunchApplication() {}
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers { blockers }
}

/// Counts calls to Sparkle's immediate-install block for the install-on-quit path.
private final class CallCounter: @unchecked Sendable {
    var count = 0
}

/// Behavior of the update relaunch gate: a ready update does not relaunch cmux while an agent
/// is mid-turn or another command is running, and relaunches once they finish.
@MainActor
@Suite struct UpdateRelaunchGateTests {
    private let clock = TestDeadlineClock()
    private let host = BlockerHost()
    private let model = UpdateStateModel()

    private func makeDriver() -> UpdateDriver {
        let driver = UpdateDriver(model: model, log: NoopUpdateLog(), clock: clock)
        driver.actionDelegate = host
        return driver
    }

    private var waitingBlockers: UpdateRelaunchBlockers? {
        guard case .installing(let installing) = model.state else { return nil }
        return installing.relaunchBlockers
    }

    /// Releases one re-check deadline and waits, bounded, for its effect.
    private func recheck(until condition: @MainActor () -> Bool) async {
        await clock.fireDeadlineWhenReady()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    @Test func relaunchesImmediatelyWhenNothingWouldBeInterrupted() {
        let driver = makeDriver()
        let box = ChoiceBox()

        driver.showReady(toInstallAndRelaunch: { box.choice = $0 })

        #expect(box.choice == .install)
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func waitsForBusyAgentsThenRelaunches() async {
        let driver = makeDriver()
        let box = ChoiceBox()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 0)

        driver.showReady(toInstallAndRelaunch: { box.choice = $0 })

        #expect(box.choice == nil)
        #expect(waitingBlockers == UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 0))
        #expect(model.text == "Update Ready")

        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        await recheck { waitingBlockers?.busyAgentCount == 1 }
        #expect(box.choice == nil)

        host.blockers = .none
        await recheck { box.choice != nil }
        #expect(box.choice == .install)
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func runningCommandsWaitForInstallNow() async {
        let driver = makeDriver()
        let box = ChoiceBox()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 1)
        driver.showReady(toInstallAndRelaunch: { box.choice = $0 })

        // The agent finishes, but the dev server is still running: keep waiting.
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 1)
        await recheck { waitingBlockers?.busyAgentCount == 0 }
        #expect(box.choice == nil)

        guard case .installing(let installing) = model.state else {
            Issue.record("expected the waiting state, got \(model.state)")
            return
        }
        installing.retryTerminatingApplication()
        #expect(box.choice == .install)
    }

    @Test func menuInstallWhileWaitingMeansInstallNow() {
        let controller = UpdateController(
            log: NoopUpdateLog(),
            clock: clock,
            isDevLikeBundle: false,
            updaterFactory: { _, _ in FakeUpdater() }
        )
        controller.actionDelegate = host
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        let box = ChoiceBox()
        controller.driver.showReady(toInstallAndRelaunch: { box.choice = $0 })
        #expect(box.choice == nil)

        controller.attemptUpdate()

        #expect(box.choice == .install)
    }

    @Test func laterDefersToInstallOnQuit() {
        let driver = makeDriver()
        let box = ChoiceBox()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        driver.showReady(toInstallAndRelaunch: { box.choice = $0 })

        guard case .installing(let installing) = model.state else {
            Issue.record("expected the waiting state, got \(model.state)")
            return
        }
        installing.dismiss()

        #expect(box.choice == .dismiss)
        #expect(model.state == .idle)
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func installOnQuitRestartNowIsGatedAndLaterReturnsToRestartPrompt() async {
        let driver = makeDriver()
        let installs = CallCounter()
        driver.showInstallOnQuitReady(immediateInstall: { installs.count += 1 })
        guard case .installing(let ready) = model.state else {
            Issue.record("expected Restart to Complete Update, got \(model.state)")
            return
        }
        #expect(ready.isAutoUpdate && ready.relaunchBlockers == nil)

        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        ready.retryTerminatingApplication()
        #expect(installs.count == 0)
        guard case .installing(let waiting) = model.state else {
            Issue.record("expected the waiting state, got \(model.state)")
            return
        }
        #expect(waiting.isAutoUpdate && waiting.relaunchBlockers?.busyAgentCount == 1)

        waiting.dismiss()
        guard case .installing(let readyAgain) = model.state else {
            Issue.record("expected Restart to Complete Update, got \(model.state)")
            return
        }
        #expect(readyAgain.relaunchBlockers == nil)

        readyAgain.retryTerminatingApplication()
        host.blockers = .none
        await recheck { installs.count == 1 }
    }

    @Test func busyAgentsStopHoldingAfterTheTimeoutButCommandsDoNot() async {
        let gate = UpdateRelaunchGate(
            clock: clock,
            log: NoopUpdateLog(),
            recheckInterval: .seconds(1),
            agentTimeout: .seconds(2)
        )
        var blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        var relaunched = 0
        gate.hold(
            isAutoUpdate: false,
            blockers: { blockers },
            publish: { _ in },
            relaunch: { relaunched += 1 },
            later: { Issue.record("later must not run") }
        )
        await recheck { gate.isWaiting }
        #expect(relaunched == 0)
        await recheck { relaunched == 1 }

        blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 1)
        gate.hold(
            isAutoUpdate: false,
            blockers: { blockers },
            publish: { _ in },
            relaunch: { relaunched += 1 },
            later: {}
        )
        for _ in 0..<3 {
            await recheck { gate.isWaiting }
        }
        // Wait for the gate to park its next re-check, so the third evaluation has run.
        await clock.fireDeadlineWhenReady()
        #expect(relaunched == 1)
        #expect(gate.isWaiting)
    }
}
