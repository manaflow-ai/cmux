import AppKit
import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextSettings
import CmuxNextTerminal
import os

/// Runs a quit (user decision 2026-09-30). `applicationShouldTerminate`
/// hands every quit here: it takes the origin (`QuitOriginTracker`), asks
/// about unsaved documents, decides (`QuitPolicy`; no quit asks how to quit), asks "Quit cmux?" when it would end running work,
/// then completes (`QuitSteps`, CmuxNextControl): save and close windows, and
/// for End end the local terminals and stop the local daemon. A failed end
/// step shows `QuitFailureAlert` (Retry or Quit Anyway). Remote sessions are
/// never ended.
@MainActor
final class QuitCoordinator {
    let origins = QuitOriginTracker()
    /// "Some sessions did not end", while it shows.
    private(set) var failureAlert: QuitFailureAlert?
    /// A quit is in progress (deciding, asking or completing).
    private(set) var isQuitting = false
    /// "Quit cmux?", while it shows (its dialog id); `signalled`: a signal answered it, so the quit goes on as a signal's does (sessions kept).
    private var confirmDialog: Int?
    private var signalled = false
    /// Runs once when the next quit is refused (an update's relaunch behind waits on that quit).
    var onQuitRefused: (() -> Void)?
    private unowned let services: AppServices
    /// The quit hook's participants (`AppServices.quitUnsaved`; tests replace it).
    var unsaved: QuitUnsavedRegistry
    /// The app's main-thread watchdog (AppDelegate): a quit that is ending
    /// stops its debug hang assertion.
    weak var watchdog: MainThreadWatchdog?
    /// Ends the process if the engine stop never returns (cx-ccjnn), recording the agent panes' state
    /// files still saving then (`AgentPaneStateLoss`). Tests replace it.
    var deadline: QuitDeadline
    /// Holds each quit step to its limit and marks its end in the launch marks.
    let steps = QuitStepLimiter(mark: { DebugTimings.markLaunch($0) })
    /// Chromium's close, the quit's last engine step (tests replace it). An app quit closes every page
    /// without its beforeunload (`cmux_shim_close_all` answers any question with Leave). The windows
    /// go away before CefShutdown blocks the main thread (2 to 3.4 s under load, cmuxterm-hq#6338),
    /// so a decided quit looks done instead of a frozen window; the deadline ends the process after.
    lazy var closeEngines: @MainActor () async -> Void = { [weak self] in
        await self?.services.cache.cef.shutdown(timeout: QuitDeadline.engineCloseWait, beforeEngineStop: QuitCoordinator.hideWindowsForEngineStop)
    }

    /// Orders out every visible window: the quit is decided and its saves ran (`stopBrowserEngines`).
    static func hideWindowsForEngineStop() {
        for window in NSApp?.windows ?? [] where window.isVisible { window.orderOut(nil) }
    }
    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.quit {wedge_engine_stop: true}`: the next quit's engine stop
    /// blocks the main thread for good, as a wedged CefShutdown did (cx-ccjnn).
    var wedgesEngineStop = false
    #endif
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")

    init(services: AppServices) {
        self.services = services
        unsaved = services.quitUnsaved
        deadline = QuitDeadline(reason: "its quit deadline was armed (a keep quit decided, or an End quit's engines began to stop)", end: services.quitDeadlineEnd())
    }

    /// Records the origin, then starts AppKit's termination. A quit already
    /// running ignores a repeat.
    func requestQuit(_ origin: QuitOrigin) {
        guard !isQuitting else { return }
        origins.record(origin)
        // From a run-loop callout, not from inside the caller's main-queue
        // job (control socket, palette): terminateLater spins a nested run
        // loop, and the save Task could never get the main queue.
        NSApplication.terminateFromRunLoop { SheetDismissal.endAll() }
    }

    /// SIGTERM, SIGINT, SIGHUP (`QuitSignal`): Quit, keep sessions, never an alert. Dev
    /// tooling quits tagged apps this way (scripts/lib/stop-app-instances.sh)
    /// and must never wait on one. An open failure alert is answered with
    /// Quit Anyway; a quit already completing is left to finish.
    func terminateFromSignal() {
        if let failureAlert { return failureAlert.answerQuitAnyway() }
        if let confirmDialog { signalled = true; CmuxDialogCenter.shared.dismiss(confirmDialog); return }
        guard !isQuitting else { return }
        requestQuit(.signal)
    }

    func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second Quit that reached AppKit directly (Dock, menu) waits for the first.
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        DebugTimings.markLaunch("quit.requested")
        // Quit (menu, Cmd-Q, socket) never waits on another open sheet.
        SheetDismissal.endAll()
        let origin = origins.consume(appleEventReason: NSAppleEventManager.shared().quitReason)
        let behavior = services.settings?.snapshot.quitBehavior ?? QuitBehaviorSetting.fallback
        logger.notice("quit origin=\(String(describing: origin), privacy: .public) behavior=\(behavior.rawValue, privacy: .public)")
        // [services]: the quit task pins the app's services until it ends (cx-6so P1b).
        Task { @MainActor [services] in
            let choice = QuitPolicy.decide(origin, behavior: behavior)
            // Unsaved documents (R96 quit hook), then "Quit cmux?" when this quit would end running work.
            guard await resolveUnsaved(origin), await confirms(origin, choice) else {
                isQuitting = false
                sender.reply(toApplicationShouldTerminate: false)
                quitRefused()
                return
            }
            await complete(signalled ? .keep : choice, sender)
        }
        return .terminateLater
    }

    /// The quit was refused: whatever waited on it learns so, once.
    private func quitRefused() {
        let refused = onQuitRefused
        onQuitRefused = nil
        refused?()
    }

    /// "Quit cmux?" (`QuitRules.confirms`, `app.confirmQuit`): Return quits, Escape cancels; true when the quit goes on. "Don't ask again" is written before the quit goes on.
    private func confirms(_ origin: QuitOrigin, _ choice: QuitSessionsChoice) async -> Bool {
        let losses = QuitLosses(agents: services.agentLanes.working.count + AgentLaneStore.chief.working.count, terminals: services.daemon.liveTerminalCount)
        guard QuitRules.confirms(origin, choice: choice, setting: services.settings?.snapshot.confirmQuit ?? CmuxConfigSnapshot.confirmQuitDefault, losses: losses) else { return true }
        let text = QuitConfirmText(losses), path = CmuxConfigSnapshot.confirmQuitPath
        let spec = DestructiveConfirmation.spec(.init(title: text.title, body: text.lines.joined(separator: " "), button: text.quit, suppresses: path))
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<CmuxDialogAnswer, Never>) in
            confirmDialog = CmuxDialogCenter.shared.present(spec, in: sheetWindow().map { .window($0) } ?? .app) { continuation.resume(returning: $0) }
        }
        confirmDialog = nil
        let quits = answer.button == DestructiveConfirmation.confirmID
        logger.notice("quit question agents=\(losses.agents) terminals=\(losses.terminals) quits=\(quits) signalled=\(self.signalled)")
        if quits, answer.values[DestructiveConfirmation.suppressID]?.bool == true { _ = try? await services.settings?.setSetting(at: path, to: .bool(false), by: .user) }
        return quits || signalled
    }

    /// The unsaved step for `origin` (`QuitUnsavedStep.resolve`).
    private func resolveUnsaved(_ origin: QuitOrigin) async -> Bool {
        let window = sheetWindow()
        return await QuitUnsavedStep.resolve(origin, registry: unsaved, scope: window.map { .window($0) } ?? .app,
                                             writeDrafts: { [drafts = services.recoveryDrafts] in await drafts.writePending() })
    }

    private func complete(_ choice: QuitSessionsChoice, _ sender: NSApplication) async {
        logger.notice("quit choice=\(choice.rawValue, privacy: .public)")
        DebugTimings.markLaunch("quit.decided")
        let services = services
        // A keep quit ends within `keepQuitLimit` from here, whatever any step
        // below does (slow quit, 2026-10-20). An End quit arms its deadline
        // once its sessions ended (the end steps show their failures).
        if !choice.ends { deadline.arm(after: QuitDeadline.keepQuitLimit) }
        // Sparkle installs a staged update as the app exits unless
        // `updates.installOnQuit` is off (then its installer is cancelled now).
        services.updater.prepareForQuit()
        // From here the quit is decided: an end before AppKit's reply (a
        // SIGKILL after a bounded wait, a slow Chromium shutdown) is still
        // a quit the user asked for, not a crash.
        // Awaited (bounded, 500 ms) so `quitting` is on disk before the quit
        // can end the process; the write itself runs off the main thread.
        await services.crashRecovery.quitBegan()
        DebugTimings.markLaunch("quit.marked")
        await quitSteps(choice).run(ends: choice.ends)
        DebugTimings.markLaunch("quit.replied")
        sender.reply(toApplicationShouldTerminate: true)
    }

    /// The quit's steps after the decision `choice` (`QuitSteps.run`).
    func quitSteps(_ choice: QuitSessionsChoice) -> QuitSteps {
        let services = services
        return QuitSteps(
            prepareWindows: { [steps] in
                let incognito = AgentQuitFiles.incognitoTabs(services.agentTabs, isIncognito: { AgentQuitFiles.isIncognito($0, in: services) })
                await QuitSaveSteps(
                    remoteSnapshots: { await services.remoteTerminals.saveSnapshots() },
                    agentComposers: { await services.agentTabs.relaunchWake.save(AgentQuitFiles.composers(services.agentTabs, isIncognito: { AgentQuitFiles.contains(incognito, $0) })) },
                    agentImages: { await services.agentTabs.launchImages.save(AgentQuitFiles.images(services.agentTabs, isIncognito: { AgentQuitFiles.contains(incognito, $0) })) },
                    terminalFrames: {
                        await TerminalLaunchFrames.beside(services.environment.sidebarSnapshotFile?.url.deletingLastPathComponent())
                            .save(services.cache.terminals.mapValues(\.session))
                    },
                    browserRecords: { await services.cache.browserTabs.flushRecords() },
                    windows: {
                        // Incognito windows' chats are purged before their spaces go (IncognitoChats), and
                        // the step waits for them: every quit, Keep included, waits for a step past its limit.
                        services.incognitoChats.closingForQuit(services)
                        await services.windows.prepareForTermination()
                        await services.incognitoChats.drain()
                    },
                    stopSavingWindows: { services.windows.stopSavingForTermination() },
                    sidebar: { await services.sidebarSnapshots.flush() },
                    homeCache: { await services.home.flushCacheForQuit() },
                    cloud: { await services.cloud.prepareForTermination() }
                ).run(steps)
                // Restart to Update: acpmux goes to the new build with the relaunch, after the saves (AcpmuxUpdateHandoff).
                if services.updater.relaunchesIntoUpdate, !choice.ends { _ = await steps.run("acpmux_update_handoff", limit: AcpmuxUpdateHandoff.quitLimit) { await AcpmuxUpdateHandoff(QuitAgents.environment(services)).handOffForQuit() } }
            },
            endLocalSessions: { await services.daemon.endSessionsAndStop(choice) },
            confirmFailures: { [weak self] failures in await self?.confirm(failures) ?? .quitAnyway },
            endLocalAgents: { [attempts = QuitAttempts()] in
                // The incognito chats' purges reach acpmux before its agents end.
                await services.incognitoChats.drain()
                // The Chief home's host ends with the sessions (home-state-ownership.md section 3),
                // and Home does not start it again.
                await services.home.brain.stop()
                let acpmux = QuitAgents.environment(services)
                // A Chief home whose acpmux is the attached daemon (`CMUX_NEXT_ACPMUX_ATTACH`) ends nothing there.
                if !QuitAgents.isAttached(acpmux, to: services.home.chief.home.acpmuxHome) {
                    await ChiefHostStop.endChiefSessions(home: services.home.chief.home,
                                                         bundledBin: Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true))
                }
                await services.home.chief.shutdownForEndSessions()
                let keep = ChiefHostStop.appAcpmuxEndKeep(chiefUsesAppAcpmux: services.home.chief.home.usesAppAcpmux)
                return await QuitAgents.end(acpmux, keep: keep, waitForShutdown: attempts.isRetry())
            },
            stopBrowserEngines: { [weak self] in
                DebugTimings.markLaunch("quit.saved")
                // Drafts typed after the save step (while "Some sessions did not end" waited) reach disk
                // before the engines stop: nothing the user asked for comes after that (QuitSteps).
                // Nothing is written when nothing changed.
                await services.home.flushCacheForQuit()
                guard let self else { return }
                // CefShutdown runs on the main thread and can block it for
                // good: from here the quit ends by a deadline whatever it
                // does (a keep quit's deadline is armed already and stays),
                // and a debug build reports that hang, never asserts it.
                deadline.arm(after: QuitDeadline.engineStopLimit)
                watchdog?.endHangAssertions()
                #if DEBUG || CMUX_BENCH_HOOKS
                if wedgesEngineStop { deadline.wedgeMainThread(watchdog) }
                #endif
                // The agent panes' and paired phones' queued saves, before the engines stop (Chromium's shutdown watchdog can end
                // the process; held to the time their close does not need) and after (a closing agent page saves its draft): that
                // wait has no limit of its own; the deadline bounds it and records what was still saving.
                let spare = deadline.timeLeft(margin: QuitDeadline.replyMargin + QuitDeadline.engineCloseWait) ?? .zero
                await steps.run("state_files", limit: spare) { await services.stateFilesDrained() }
                await closeEngines()
                DebugTimings.markLaunch("quit.engines_stopped")
                await services.stateFilesDrained()
            },
            limiter: steps, timeLeft: { [deadline] in deadline.timeLeft(margin: QuitDeadline.replyMargin) }
        )
    }

    /// Shows "Some sessions did not end" and waits for the answer.
    private func confirm(_ failures: [EndSessionsFailure]) async -> QuitFailureAnswer {
        await withCheckedContinuation { continuation in
            let alert = QuitFailureAlert(failures: failures) { [weak self] answer in
                self?.failureAlert = nil
                self?.logger.info("quit end failures answer=\(String(describing: answer), privacy: .public)")
                continuation.resume(returning: answer)
            }
            failureAlert = alert
            alert.present(in: sheetWindow())
        }
    }

    /// The active shell window when it can carry a sheet.
    private func sheetWindow() -> NSWindow? {
        let candidates = [services.windows.active?.window, NSApp?.mainWindow] + services.windows.controllers.map(\.window)
        return candidates.compactMap { $0 }.first { $0.isVisible && !$0.isMiniaturized && $0.attachedSheet == nil }
    }
}
