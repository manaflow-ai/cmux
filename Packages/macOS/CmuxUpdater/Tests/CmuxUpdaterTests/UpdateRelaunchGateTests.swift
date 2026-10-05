import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Host double that reports whatever blockers the test sets.
@MainActor
private final class BlockerHost: UpdateActionDelegate {
    var blockers = UpdateRelaunchBlockers.empty

    func updaterRequestsRetryCheckForUpdates() {}
    func updaterWillRelaunchApplication() {}
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers { blockers }
}

/// Counts calls to Sparkle's immediate-install block for the install-on-quit path.
private final class CallCounter: @unchecked Sendable {
    var count = 0
}

/// Behavior of the update relaunch gate: Sparkle's install-and-relaunch does not relaunch
/// cmux while an agent is mid-turn or another command is running, and relaunches once they
/// finish. Sparkle routes every relaunching install (Install and Relaunch, Restart Now, and a
/// resumed install after Later) through `shouldPostponeRelaunchForUpdate`, which the driver
/// answers with ``UpdateDriver/handleShouldPostponeRelaunch(installHandler:)``.
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

    private var installing: UpdateState.Installing? {
        guard case .installing(let installing) = model.state else { return nil }
        return installing
    }

    /// Releases one re-check deadline and waits, bounded, for its effect. The bounds only
    /// catch a hang; they are generous so a loaded CI host does not fail a correct run.
    private func recheck(until condition: @MainActor () -> Bool) async {
        await clock.fireDeadlineWhenReady(timeout: .seconds(20))
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    @Test func relaunchesImmediatelyWhenNothingWouldBeInterrupted() {
        let driver = makeDriver()

        #expect(!driver.handleShouldPostponeRelaunch(installHandler: {}))
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func waitsForBusyAgentsThenRelaunches() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 0)

        #expect(driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 }))

        #expect(installs.count == 0)
        #expect(waitingBlockers == UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 0))
        #expect(model.text == "Update Ready")

        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        await recheck { waitingBlockers?.busyAgentCount == 1 }
        #expect(installs.count == 0)

        host.blockers = .empty
        await recheck { installs.count == 1 }
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func runningCommandsWaitForInstallNow() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 1)
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })

        // The agent finishes, but the dev server is still running: keep waiting.
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 1)
        await recheck { waitingBlockers?.busyAgentCount == 0 }
        #expect(installs.count == 0)

        installing?.retryTerminatingApplication()
        #expect(installs.count == 1)
        #expect(!driver.relaunchGate.isWaiting)
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
        let installs = CallCounter()
        _ = controller.driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })
        #expect(installs.count == 0)

        controller.attemptUpdate()

        #expect(installs.count == 1)
    }

    @Test func laterKeepsUpdateReadyAndRestartNowHonorsExplicitConfirmation() {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })

        installing?.dismiss()
        #expect(installs.count == 0)
        #expect(!driver.relaunchGate.isWaiting)
        #expect(installing?.isAutoUpdate == true)
        #expect(installing?.relaunchBlockers == nil)
        #expect(model.text == "Update Ready")

        // Restart Later must not drop the postponed install: Sparkle's session stays open
        // until it runs, so the prompt stays and Restart Now still reaches it.
        installing?.dismiss()
        #expect(model.text == "Update Ready")

        installing?.retryTerminatingApplication()
        #expect(installs.count == 1)
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func explicitInstallContinuationBypassesTheGateOnce() {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 1)

        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })
        installing?.retryTerminatingApplication()
        #expect(installs.count == 1)

        // Sparkle may ask again while carrying out the explicit install. The confirmation should
        // allow that one callback through instead of reopening the same waiting prompt.
        #expect(!driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 }))
        #expect(installs.count == 1)

        // The bypass is one-shot; a new relaunch request still observes the blocker.
        #expect(driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 }))
    }

    @Test func retryingAnUnterminatedInstallHonorsExplicitConfirmation() {
        let driver = makeDriver()
        let retries = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 1)

        driver.showInstallingUpdate(
            withApplicationTerminated: false,
            retryTerminatingApplication: { retries.count += 1 }
        )
        installing?.retryTerminatingApplication()

        #expect(retries.count == 1)
        #expect(!driver.handleShouldPostponeRelaunch(installHandler: { retries.count += 1 }))
    }

    @Test func repeatedRestartNowInstallsOnce() {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })
        installing?.dismiss()
        let restartPrompt = installing

        host.blockers = .empty
        restartPrompt?.retryTerminatingApplication()
        restartPrompt?.retryTerminatingApplication()

        #expect(installs.count == 1)
    }

    @Test func updaterErrorWhileHeldEndsTheHoldWithoutInstalling() {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })

        driver.showUpdaterError(NSError(domain: "test", code: 1), acknowledgement: {})

        #expect(!driver.relaunchGate.isWaiting)
        #expect(installs.count == 0)
        guard case .error = model.state else {
            Issue.record("expected the error to stay visible, got \(model.state)")
            return
        }
    }

    @Test func finishedUpdateCycleEndsTheHold() {
        let driver = makeDriver()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        _ = driver.handleShouldPostponeRelaunch(installHandler: {})

        driver.handleDidFinishUpdateCycle(.updates, error: nil)

        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func replacedWaitingStateEndsTheHoldWithoutTouchingTheNewState() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })

        model.setState(.idle)
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 0)
        await recheck { !driver.relaunchGate.isWaiting }

        #expect(model.state == .idle)
        #expect(installs.count == 0)
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
        var evaluations = 0
        gate.hold(
            isAutoUpdate: false,
            blockers: {
                evaluations += 1
                return blockers
            },
            isShown: { true },
            publish: { _ in },
            relaunch: { relaunched += 1 },
            later: { Issue.record("later must not run") }
        )
        #expect(evaluations == 1)
        await recheck { evaluations == 2 }
        #expect(relaunched == 0)
        await recheck { relaunched == 1 }

        blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 1)
        evaluations = 0
        gate.hold(
            isAutoUpdate: false,
            blockers: {
                evaluations += 1
                return blockers
            },
            isShown: { true },
            publish: { _ in },
            relaunch: { relaunched += 1 },
            later: {}
        )
        for expected in 2...4 {
            await recheck { evaluations == expected }
        }
        #expect(relaunched == 1)
        #expect(gate.isWaiting)
    }
}
