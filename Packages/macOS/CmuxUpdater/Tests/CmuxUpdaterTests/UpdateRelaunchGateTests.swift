import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Host double that reports whatever blockers the test sets.
@MainActor
private final class BlockerHost: UpdateActionDelegate {
    var blockers = UpdateRelaunchBlockers.empty
    var allowsAutomaticInstall = true
    var automaticInstallsPrepared = 0

    func updaterRequestsRetryCheckForUpdates() {}
    func updaterPrepareAutomaticInstall() -> Bool {
        automaticInstallsPrepared += 1
        return allowsAutomaticInstall
    }
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

    private func makeDriver(
        agentTimeout: Duration = UpdateRelaunchGate.agentTimeout,
        daemonUnavailableTimeout: Duration = UpdateRelaunchGate.daemonUnavailableTimeout
    ) -> UpdateDriver {
        let driver = UpdateDriver(model: model, log: NoopUpdateLog(), clock: clock,
                                  relaunchAgentTimeout: agentTimeout,
                                  relaunchDaemonUnavailableTimeout: daemonUnavailableTimeout)
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

    /// What the host reports right after a click: the click itself is input inside the quiet
    /// window, and the daemon mirror may be reconnecting.
    private static let clickTimeBlockers = UpdateRelaunchBlockers(
        busyAgentCount: 0, runningCommandCount: 0, userInputActive: true, daemonStateUnavailable: true)

    @Test func aClickInstallIsNotHeldByTheClickOrAnUnconfirmedDaemon() {
        let driver = makeDriver()
        host.blockers = Self.clickTimeBlockers

        #expect(!driver.handleShouldPostponeRelaunch(installHandler: {}))
        #expect(!driver.relaunchGate.isWaiting)
    }

    /// A host that preserves sessions can disable the gate for both click-driven and automatic
    /// installs; generic hosts still exercise the gate below.
    @Test func aHostThatDoesNotHoldUserInstallsRelaunchesAClickOverBusyWork() {
        let driver = makeDriver()
        driver.holdsUserInstalls = false
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 1)

        #expect(!driver.handleShouldPostponeRelaunch(installHandler: {}))
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func aSessionPreservingHostRelaunchesAnAutomaticInstallOverLiveWork() {
        let driver = makeDriver()
        driver.holdsUserInstalls = false
        driver.relaunchIsAutomatic = true
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 9, runningCommandCount: 4)

        #expect(!driver.handleShouldPostponeRelaunch(installHandler: {}))
        #expect(!driver.relaunchGate.isWaiting)
        #expect(model.state == .idle)
    }

    @Test func restartNowAfterLaterIsNotHeldByTheClickOrAnUnconfirmedDaemon() {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })
        installing?.dismiss()
        #expect(model.text == "Restart to Complete Update")

        host.blockers = Self.clickTimeBlockers
        installing?.retryTerminatingApplication()

        #expect(installs.count == 1)
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func restartNowAfterLaterStopsWaitingForBusyAgentsAtTheTimeout() async {
        let driver = makeDriver(agentTimeout: .seconds(2))
        let installs = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })
        installing?.dismiss()

        installing?.retryTerminatingApplication()
        #expect(installs.count == 0)
        #expect(waitingBlockers?.busyAgentCount == 1)

        await recheck { installs.count == 1 }
        #expect(!driver.relaunchGate.isWaiting)
    }

    /// Stages a background download the way Sparkle does; with the idle policy on, the driver
    /// hands it to Sparkle without a click.
    private func stageWithIdlePolicy(_ driver: UpdateDriver, clicked: Bool = false) {
        driver.installsInBackground = true
        driver.installsWhenIdle = true
        driver.installsWhenStaged = clicked
        driver.showReady(toInstallAndRelaunch: { _ in })
    }

    @Test func anAutomaticInstallWaitsForQuietInput() async {
        let driver = makeDriver()
        let installs = CallCounter()
        stageWithIdlePolicy(driver)
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 0, runningCommandCount: 0, userInputActive: true)

        #expect(driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 }))
        #expect(installs.count == 0)

        host.blockers = .empty
        await recheck { installs.count == 1 }
    }

    @Test func anAutomaticInstallWaitsForBusyAgentsWithoutATimeout() async {
        let driver = makeDriver(agentTimeout: .seconds(2))
        let installs = CallCounter()
        stageWithIdlePolicy(driver)
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)

        #expect(driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 }))
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 0)
        await recheck { waitingBlockers?.busyAgentCount == 2 }
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        await recheck { waitingBlockers?.busyAgentCount == 1 }
        #expect(installs.count == 0)
        #expect(driver.relaunchGate.isWaiting)
    }

    /// The host runs a click's checks (preflight, What's New record, rollback copy) before an
    /// automatic install; a failed preflight keeps the update staged and opens nothing.
    @Test func anAutomaticInstallAsksTheHostFirstAndStaysStagedWhenItDeclines() {
        let driver = makeDriver()
        let replies = CallCounter()
        driver.installsInBackground = true
        driver.installsWhenIdle = true
        host.allowsAutomaticInstall = false

        driver.showReady(toInstallAndRelaunch: { _ in replies.count += 1 })

        #expect(host.automaticInstallsPrepared == 1)
        #expect(replies.count == 0)
        #expect(model.text == "Restart to Complete Update")
        #expect(driver.stagedInstall != nil)
    }

    @Test func anAutomaticInstallTheHostPreparedIsHandedToSparkle() {
        let driver = makeDriver()
        let replies = CallCounter()
        driver.installsInBackground = true
        driver.installsWhenIdle = true

        driver.showReady(toInstallAndRelaunch: { _ in replies.count += 1 })

        #expect(host.automaticInstallsPrepared == 1)
        #expect(replies.count == 1)
        #expect(driver.relaunchIsAutomatic)
    }

    /// The idle policy never waits past its cap: busy agents, a running command and recent
    /// input all give way, and the relaunch keeps every session (Leo: updates just install).
    @Test func anAutomaticInstallRelaunchesAtTheWaitCapWhateverIsRunning() async {
        let driver = makeDriver()
        driver.relaunchGate.automaticWaitCap = .seconds(4)
        let installs = CallCounter()
        stageWithIdlePolicy(driver)
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 1, userInputActive: true)

        #expect(driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 }))
        await recheck { driver.relaunchGate.isWaiting }
        #expect(installs.count == 0)

        await recheck { installs.count == 1 }
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func theWaitCapBoundsOnlyAutomaticInstalls() {
        let busy = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 1, userInputActive: true)
        func relaunches(automatic: Bool, waited: Duration) -> Bool {
            UpdateRelaunchGate.shouldRelaunch(
                automatic ? busy : busy.forUserInstall, automatic: automatic, waited: waited,
                daemonUnavailableFor: .zero, agentTimeout: .seconds(30 * 60),
                daemonUnavailableTimeout: .seconds(10 * 60), automaticWaitCap: .seconds(15 * 60))
        }

        #expect(!relaunches(automatic: true, waited: .seconds(15 * 60 - 2)))
        #expect(relaunches(automatic: true, waited: .seconds(15 * 60)))
        // A host that holds user installs keeps holding them for a running command.
        #expect(!relaunches(automatic: false, waited: .seconds(60 * 60)))
    }

    @Test func theDefaultWaitCapIsFifteenMinutes() {
        #expect(UpdateRelaunchGate.automaticWaitCap == .seconds(15 * 60))
        #expect(makeDriver().relaunchGate.automaticWaitCap == .seconds(15 * 60))
    }

    @Test func anAutomaticInstallStopsWaitingForAnUnconfirmedDaemonAtTheBound() async {
        let driver = makeDriver(daemonUnavailableTimeout: .seconds(4))
        let installs = CallCounter()
        stageWithIdlePolicy(driver)
        host.blockers = .daemonUnavailable

        #expect(driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 }))
        // A confirmed read in between restarts the bound.
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        await recheck { waitingBlockers?.busyAgentCount == 1 }
        host.blockers = .daemonUnavailable
        await recheck { waitingBlockers == .daemonUnavailable }
        #expect(installs.count == 0)

        await recheck { installs.count == 1 }
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func aClickDuringTheDownloadIsAUserInstallEvenWithTheIdlePolicyOn() {
        let driver = makeDriver()
        stageWithIdlePolicy(driver, clicked: true)
        host.blockers = Self.clickTimeBlockers

        #expect(!driver.handleShouldPostponeRelaunch(installHandler: {}))
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func aMenuInstallWithTheIdlePolicyOnIsAUserInstall() {
        let controller = UpdateController(
            log: NoopUpdateLog(),
            clock: clock,
            isDevLikeBundle: false,
            updaterFactory: { _, _ in FakeUpdater() }
        )
        controller.actionDelegate = host
        controller.installsUpdatesInBackground = true
        controller.installsUpdatesWhenIdle = true

        controller.attemptUpdate()
        controller.driver.showReady(toInstallAndRelaunch: { _ in })
        host.blockers = Self.clickTimeBlockers

        #expect(!controller.driver.handleShouldPostponeRelaunch(installHandler: {}))
        #expect(!controller.driver.relaunchGate.isWaiting)
    }

    @Test func aFinishedCycleSpendsAnUnusedAutomaticMark() {
        let driver = makeDriver()
        stageWithIdlePolicy(driver)
        #expect(driver.relaunchIsAutomatic)

        driver.handleDidFinishUpdateCycle(.updates, error: nil)

        #expect(!driver.relaunchIsAutomatic)
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

    @Test func laterKeepsRestartToCompleteAndRestartNowIsGatedAgain() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = UpdateRelaunchBlockers(busyAgentCount: 1, runningCommandCount: 0)
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })

        installing?.dismiss()
        #expect(installs.count == 0)
        #expect(!driver.relaunchGate.isWaiting)
        #expect(installing?.isAutoUpdate == true)
        #expect(installing?.relaunchBlockers == nil)
        #expect(model.text == "Restart to Complete Update")

        // Restart Later must not drop the postponed install: Sparkle's session stays open
        // until it runs, so the prompt stays and Restart Now still reaches it.
        installing?.dismiss()
        #expect(model.text == "Restart to Complete Update")

        installing?.retryTerminatingApplication()
        #expect(installs.count == 0)
        #expect(waitingBlockers?.busyAgentCount == 1)

        host.blockers = .empty
        await recheck { installs.count == 1 }
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
