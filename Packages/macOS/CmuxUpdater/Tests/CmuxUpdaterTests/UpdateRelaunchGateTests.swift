import Foundation
import Testing
@preconcurrency import Sparkle
@testable import CmuxUpdater

/// Host double that reports whatever blockers and input idle time the test sets, and counts
/// the pre-relaunch captures. `onPrepare` runs inside the capture, to change the world while
/// it is in flight.
@MainActor
private final class RelaunchHost: UpdateActionDelegate {
    var blockers = UpdateRelaunchBlockers.empty
    var idle: Duration = .seconds(600)
    var prepareCount = 0
    var onPrepare: (@MainActor () -> Void)?

    func updaterRequestsRetryCheckForUpdates() {}
    func updaterPrepareForRelaunch() async {
        prepareCount += 1
        onPrepare?()
    }
    func updaterWillRelaunchApplication() {}
    func updaterRelaunchBlockers() -> UpdateRelaunchBlockers { blockers }
    func updaterTimeSinceLastUserInput() -> Duration { idle }
}

/// A report with `risky` risky agents, `care` agents resuming mid-task, and `commands` other
/// running commands.
private func blockers(risky: Int = 0, care: Int = 0, commands: Int = 0) -> UpdateRelaunchBlockers {
    let riskyAgents = (0..<risky).map {
        UpdateRelaunchAgent(id: "risky-\($0)", name: "Claude Code", location: "w", safety: .risky, activity: "Bash: swift build")
    }
    let careAgents = (0..<care).map {
        UpdateRelaunchAgent(id: "care-\($0)", name: "Codex", location: "w", safety: .care, activity: "Thinking")
    }
    return UpdateRelaunchBlockers(agents: riskyAgents + careAgents, runningCommandCount: commands)
}

/// Counts calls to Sparkle's install block.
private final class CallCounter: @unchecked Sendable {
    var count = 0
}

/// Behavior of update relaunches. An install the user asked for relaunches right after the host
/// captures its sessions, whatever is running (#15084). An automatic install (the "Install
/// Updates Automatically" setting) waits for a quiet moment: no busy agent, no running command,
/// and a minute without input. Sparkle asks `shouldPostponeRelaunchForUpdate` once per install,
/// which the driver answers with ``UpdateDriver/handleShouldPostponeRelaunch(installHandler:)``.
@MainActor
@Suite struct UpdateRelaunchGateTests {
    private let clock = TestDeadlineClock()
    private let host = RelaunchHost()
    private let model = UpdateStateModel()

    private func makeDriver(installsAutomatically: Bool = true) -> UpdateDriver {
        let driver = UpdateDriver(model: model, log: NoopUpdateLog(), clock: clock)
        driver.actionDelegate = host
        driver.installsAutomatically = { installsAutomatically }
        return driver
    }

    /// Starts an automatic install the way Sparkle does: the background download finishes, the
    /// driver runs the immediate-install block, and Sparkle asks whether to postpone.
    private func startAutomaticInstall(_ driver: UpdateDriver, installs: CallCounter) {
        let handled = driver.handleWillInstallUpdateOnQuit(immediateInstallHandler: {
            #expect(driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 }))
        })
        #expect(handled)
    }

    private var waitingBlockers: UpdateRelaunchBlockers? {
        guard case .installing(let installing) = model.state else { return nil }
        return installing.relaunchBlockers
    }

    private var installing: UpdateState.Installing? {
        guard case .installing(let installing) = model.state else { return nil }
        return installing
    }

    /// Waits, bounded, for an effect of work already scheduled on the main actor.
    private func settle(until condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    /// Releases one re-check deadline and waits, bounded, for its effect. The bounds only
    /// catch a hang; they are generous so a loaded CI host does not fail a correct run.
    private func recheck(until condition: @MainActor () -> Bool) async {
        await clock.fireDeadlineWhenReady(timeout: .seconds(20))
        await settle(until: condition)
    }

    /// Releases one re-check deadline and waits until the gate has handled it and is waiting
    /// for the next one.
    private func tick() async {
        await clock.fireDeadlineWhenReady(timeout: .seconds(20))
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while await !clock.hasParkedDeadline, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(await clock.hasParkedDeadline)
    }

    // MARK: - Installs the user asked for

    @Test func userInstallRelaunchesRightAwayWhenOnlySafeAndCareAgentsRun() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = blockers(care: 3)
        host.idle = .zero

        #expect(driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 }))

        await settle { installs.count == 1 }
        #expect(host.prepareCount == 1)
        #expect(!driver.relaunchGate.isWaiting)
        #expect(waitingBlockers == nil)
    }

    @Test func userInstallWithRiskyAgentsAsksAndUpdateAnywayRelaunches() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = blockers(risky: 1, care: 2, commands: 1)
        host.idle = .zero

        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })

        #expect(driver.relaunchGate.mode == .askUser)
        #expect(installing?.updateWhenClear != nil)
        #expect(waitingBlockers?.riskyAgents.count == 1)
        #expect(model.description == "Relaunching now stops what these are running. 2 agents will be resumed mid-task.")
        // Asking never relaunches on its own, even once the risky agent finishes.
        host.blockers = blockers(care: 2)
        await tick()
        #expect(installs.count == 0)

        installing?.retryTerminatingApplication()
        await settle { installs.count == 1 }
        #expect(host.prepareCount == 1)
    }

    @Test func updateWhenTheseFinishRelaunchesOnceRiskyAgentsClear() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = blockers(risky: 2)
        host.idle = .zero
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })

        installing?.updateWhenClear?()
        #expect(driver.relaunchGate.mode == .whenClear)
        #expect(installing?.updateWhenClear == nil)

        await tick()
        #expect(installs.count == 0)
        // Care agents and recent input do not hold a relaunch the user asked for.
        host.blockers = blockers(care: 1)
        await recheck { installs.count == 1 }
    }

    @Test func waitLeavesRestartToCompleteAndAsksAgainOnRestartNow() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = blockers(risky: 1)
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })

        installing?.dismiss()
        #expect(model.text == "Restart to Complete Update")
        #expect(!driver.relaunchGate.isWaiting)

        installing?.retryTerminatingApplication()
        #expect(driver.relaunchGate.mode == .askUser)
        #expect(installs.count == 0)
    }

    @Test func updateDownloadedWithAutomaticInstallsOffWaitsForRestart() async {
        let driver = makeDriver(installsAutomatically: false)
        let installs = CallCounter()

        let handled = driver.handleWillInstallUpdateOnQuit(immediateInstallHandler: {
            _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })
        })

        #expect(handled)
        #expect(model.text == "Restart to Complete Update")
        #expect(installs.count == 0)

        installing?.retryTerminatingApplication()
        await settle { installs.count == 1 }
        #expect(host.prepareCount == 1)
    }

    // MARK: - Automatic installs

    @Test func automaticInstallWaitsForAQuietMomentThenRelaunches() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.idle = .seconds(5)

        startAutomaticInstall(driver, installs: installs)

        #expect(driver.relaunchGate.isWaiting)
        #expect(waitingBlockers == .empty)
        #expect(model.text == "Update Ready")

        await tick()
        #expect(installs.count == 0)
        #expect(host.prepareCount == 0)

        host.idle = .seconds(61)
        await recheck { installs.count == 1 }
        #expect(host.prepareCount == 1)
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func automaticInstallDoesNotWaitForCareAgents() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = blockers(care: 3)
        startAutomaticInstall(driver, installs: installs)
        #expect(model.description.hasSuffix("3 agents will be resumed mid-task."))

        await recheck { installs.count == 1 }
    }

    @Test func automaticInstallWaitsForRiskyAgentsWithoutATimeout() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = blockers(risky: 2, commands: 0)

        startAutomaticInstall(driver, installs: installs)
        #expect(waitingBlockers?.riskyAgents.count == 2)

        for _ in 0..<5 {
            await tick()
        }
        #expect(waitingBlockers?.riskyAgents.count == 2)
        host.blockers = blockers(risky: 1, commands: 0)
        await tick()
        #expect(waitingBlockers?.riskyAgents.count == 1)
        #expect(installs.count == 0)

        host.blockers = .empty
        await recheck { installs.count == 1 }
    }

    @Test func automaticInstallNeverStopsARunningCommandButInstallNowDoes() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = blockers(risky: 0, commands: 1)

        startAutomaticInstall(driver, installs: installs)
        for _ in 0..<3 {
            await tick()
        }
        #expect(waitingBlockers?.runningCommandCount == 1)
        #expect(installs.count == 0)

        installing?.retryTerminatingApplication()
        await settle { installs.count == 1 }
        #expect(host.prepareCount == 1)
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func agentThatStartsATurnDuringPrepareKeepsTheUpdateWaiting() async {
        let driver = makeDriver()
        let installs = CallCounter()
        startAutomaticInstall(driver, installs: installs)

        // The quiet moment arrives, but an agent starts a turn while the host captures its
        // sessions: relaunching now would cut that turn off.
        host.onPrepare = { [host] in
            host.blockers = blockers(risky: 1, commands: 0)
        }
        await tick()
        #expect(host.prepareCount == 1)
        #expect(waitingBlockers?.riskyAgents.count == 1)
        #expect(installs.count == 0)
        #expect(driver.relaunchGate.isWaiting)

        host.onPrepare = nil
        host.blockers = .empty
        await recheck { installs.count == 1 }
        #expect(host.prepareCount == 2)
    }

    @Test func userReturningDuringPrepareKeepsTheUpdateWaiting() async {
        let driver = makeDriver()
        let installs = CallCounter()
        startAutomaticInstall(driver, installs: installs)

        host.onPrepare = { [host] in host.idle = .milliseconds(200) }
        await tick()
        #expect(host.prepareCount == 1)
        #expect(installs.count == 0)
        #expect(driver.relaunchGate.isWaiting)
    }

    @Test func menuInstallWhileWaitingMeansInstallNow() async {
        let controller = UpdateController(
            log: NoopUpdateLog(),
            clock: clock,
            isDevLikeBundle: false,
            updaterFactory: { _, _ in FakeUpdater() }
        )
        controller.actionDelegate = host
        controller.driver.installsAutomatically = { true }
        host.blockers = blockers(risky: 1, commands: 0)
        let installs = CallCounter()
        startAutomaticInstall(controller.driver, installs: installs)
        #expect(installs.count == 0)

        controller.attemptUpdate()

        await settle { installs.count == 1 }
    }

    @Test func laterKeepsRestartToCompleteAndRestartNowInstallsOnce() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = blockers(risky: 1, commands: 0)
        startAutomaticInstall(driver, installs: installs)

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

        // Restart Now is the user's choice: once nothing is risky it relaunches right away.
        host.blockers = blockers(care: 1)
        host.idle = .zero
        let restartPrompt = installing
        restartPrompt?.retryTerminatingApplication()
        restartPrompt?.retryTerminatingApplication()
        await settle { installs.count == 1 }
        for _ in 0..<10 { await Task.yield() }
        #expect(installs.count == 1)
    }

    @Test func updaterErrorWhileHeldEndsTheHoldWithoutInstalling() {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = blockers(risky: 1, commands: 0)
        startAutomaticInstall(driver, installs: installs)

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
        host.blockers = blockers(risky: 1, commands: 0)
        startAutomaticInstall(driver, installs: CallCounter())

        driver.handleDidFinishUpdateCycle(.updates, error: nil)

        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func finishedCycleForgetsAnAutomaticInstallSparkleNeverAskedAbout() async {
        let driver = makeDriver()
        let installs = CallCounter()
        // Sparkle aborted before asking about the relaunch.
        _ = driver.handleWillInstallUpdateOnQuit(immediateInstallHandler: {})
        driver.handleDidFinishUpdateCycle(.updates, error: nil)

        // A later install the user asks for must not be held as if it were automatic (an
        // automatic hold would wait for a quiet minute; this one relaunches).
        host.blockers = blockers(care: 1)
        host.idle = .zero
        _ = driver.handleShouldPostponeRelaunch(installHandler: { installs.count += 1 })
        await settle { installs.count == 1 }
        #expect(!driver.relaunchGate.isWaiting)
    }

    @Test func replacedWaitingStateEndsTheHoldWithoutTouchingTheNewState() async {
        let driver = makeDriver()
        let installs = CallCounter()
        host.blockers = blockers(risky: 1, commands: 0)
        startAutomaticInstall(driver, installs: installs)

        model.setState(.idle)
        host.blockers = .empty
        await recheck { !driver.relaunchGate.isWaiting }

        #expect(model.state == .idle)
        #expect(installs.count == 0)
    }

    private func isQuietMoment(_ readiness: UpdateRelaunchGate.Readiness, quietPeriod: Duration) -> Bool {
        UpdateRelaunchGate.mayRelaunch(readiness, mode: .quietMoment, quietPeriod: quietPeriod)
    }

    @Test func quietMomentNeedsNothingRiskyAndAQuietMinute() {
        let quiet = UpdateRelaunchGate.quietPeriod
        #expect(isQuietMoment(.init(blockers: .empty, idle: quiet), quietPeriod: quiet))
        #expect(!isQuietMoment(.init(blockers: .empty, idle: .seconds(59)), quietPeriod: quiet))
        #expect(isQuietMoment(.init(blockers: blockers(care: 2), idle: quiet), quietPeriod: quiet))
        #expect(!isQuietMoment(
            .init(blockers: blockers(risky: 1, commands: 0), idle: .seconds(3600)),
            quietPeriod: quiet
        ))
        #expect(!isQuietMoment(
            .init(blockers: blockers(risky: 0, commands: 1), idle: .seconds(3600)),
            quietPeriod: quiet
        ))
    }
}
