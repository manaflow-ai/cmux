import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextSettings
import CmuxNextTerminal
import os

/// Runs a quit (user decision 2026-09-30). `applicationShouldTerminate`
/// hands every quit here: it takes the origin (`QuitOriginTracker`), reads
/// the local terminals for an interactive quit, decides (`QuitPolicy`),
/// shows `QuitAlert` when asked to, then completes (`QuitSteps`, CmuxNextControl):
/// remember the choice, save and close windows, and for End end the local
/// terminals and stop the local daemon. A failed end step shows
/// `QuitFailureAlert` (Retry or Quit Anyway). Remote sessions are never ended.
@MainActor
final class QuitCoordinator {
    let origins = QuitOriginTracker()
    private(set) var sheet: QuitAlert?
    /// "Some sessions did not end", while it shows.
    private(set) var failureAlert: QuitFailureAlert?
    /// A quit is in progress (deciding, asking or completing).
    private(set) var isQuitting = false
    /// Runs once when the next quit is refused (an update's relaunch behind waits on that quit).
    var onQuitRefused: (() -> Void)?
    /// The last dialog brought the app forward (`debug.quit`).
    private(set) var lastAskActivated = false
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
    /// without its beforeunload (`cmux_shim_close_all` answers any question with Leave).
    lazy var closeEngines: @MainActor () async -> Void = { [weak self] in await self?.services.cache.cef.shutdown(timeout: QuitDeadline.engineCloseWait) }
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

    /// Records the origin, then starts AppKit's termination. A second Cmd-Q
    /// while the dialog asks confirms its default (keep); a quit already
    /// completing ignores a repeat.
    func requestQuit(_ origin: QuitOrigin) {
        guard !isQuitting else {
            if origin == .interactive { sheet?.answerDefault() }
            return
        }
        origins.record(origin)
        // From a run-loop callout, not from inside the caller's main-queue
        // job (control socket, palette): terminateLater spins a nested run
        // loop, and the save Task could never get the main queue.
        NSApplication.terminateFromRunLoop { SheetDismissal.endAll() }
    }

    /// SIGTERM, SIGINT, SIGHUP (`QuitSignal`): Quit, keep sessions, never an alert. Dev
    /// tooling quits tagged apps this way (scripts/lib/stop-app-instances.sh)
    /// and must never wait on the alert. An open alert is answered with
    /// keep; a quit already completing is left to finish.
    func terminateFromSignal() {
        if let sheet { return sheet.answerKeepingSessions() }
        if let failureAlert { return failureAlert.answerQuitAnyway() }
        guard !isQuitting else { return }
        requestQuit(.signal)
    }

    func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else {
            // A second Quit that reached AppKit directly (Dock, menu).
            sheet?.answerDefault()
            return .terminateLater
        }
        isQuitting = true
        DebugTimings.markLaunch("quit.requested")
        // Quit (menu, Cmd-Q, socket) never waits on another open sheet.
        SheetDismissal.endAll()
        let origin = origins.consume(appleEventReason: Self.quitReason())
        let behavior = services.settings?.snapshot.quitBehavior ?? QuitBehaviorSetting.fallback
        logger.notice("quit origin=\(String(describing: origin), privacy: .public) behavior=\(behavior.rawValue, privacy: .public)")
        // [services]: the quit task pins the app's services until it ends (cx-6so P1b).
        Task { @MainActor [services] in
            // Unsaved documents come first (R96 quit hook). Answering that
            // question is the quit's one dialog: the sessions are not asked
            // about after it (#17501).
            let askedUnsaved = origin == .interactive && !unsaved.unsaved().isEmpty
            guard await resolveUnsaved(origin) else {
                isQuitting = false
                sender.reply(toApplicationShouldTerminate: false)
                quitRefused()
                return
            }
            let facts = QuitPolicy.needsFacts(origin) && !askedUnsaved ? await QuitFactsReader.read(services) : .none
            switch QuitPolicy.decide(origin, behavior: behavior, facts: facts, alreadyAsked: askedUnsaved) {
            case .quit(let choice):
                await complete(choice, remember: false, sender)
            case .ask(let prompt):
                ask(prompt, sender, activate: Self.shouldActivate(origin, isActive: sender.isActive,
                                                                  noActivate: WindowPlacement.noActivate))
            }
        }
        return .terminateLater
    }

    /// The quit was refused: whatever waited on it learns so, once.
    private func quitRefused() {
        let refused = onQuitRefused
        onQuitRefused = nil
        refused?()
    }

    /// The unsaved step for `origin` (`QuitUnsavedStep.resolve`).
    private func resolveUnsaved(_ origin: QuitOrigin) async -> Bool {
        let window = sheetWindow()
        return await QuitUnsavedStep.resolve(origin, registry: unsaved, scope: window.map { .window($0) } ?? .app,
                                             writeDrafts: { [drafts = services.recoveryDrafts] in await drafts.writePending() })
    }

    /// A quit from the Dock or the app switcher while cmux is inactive is the
    /// user's: cmux comes forward so the dialog is seen. Never in a
    /// no-activate launch; non-interactive quits never ask.
    static func shouldActivate(_ origin: QuitOrigin, isActive: Bool, noActivate: Bool) -> Bool {
        origin == .interactive && !isActive && !noActivate
    }

    private func ask(_ prompt: QuitPrompt, _ sender: NSApplication, activate: Bool) {
        lastAskActivated = activate
        if activate { sender.activate() }
        let sheet = QuitAlert(prompt: prompt) { [weak self] answer in
            guard let self else { return }
            self.sheet = nil
            switch answer {
            case .cancel:
                self.isQuitting = false
                sender.reply(toApplicationShouldTerminate: false)
                self.quitRefused()
            case .quit(let choice, let remember):
                Task { @MainActor [services] in
                    await self.complete(choice, remember: remember, sender)
                    withExtendedLifetime(services) {} // pins the app's services until the quit ends
                }
            }
        }
        self.sheet = sheet
        sheet.present(in: sheetWindow())
    }

    private func complete(_ choice: QuitSessionsChoice, remember: Bool, _ sender: NSApplication) async {
        logger.notice("quit choice=\(choice.rawValue, privacy: .public) remember=\(remember)")
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
        await quitSteps(choice).run(ends: choice.ends, remember: remember ? QuitPolicy.remembered(choice) : nil)
        DebugTimings.markLaunch("quit.replied")
        sender.reply(toApplicationShouldTerminate: true)
    }

    /// The quit's steps after the decision `choice` (`QuitSteps.run`).
    func quitSteps(_ choice: QuitSessionsChoice) -> QuitSteps {
        let services = services
        return QuitSteps(
            remember: { behavior in
                guard let settings = services.settings,
                      let descriptor = SettingsSchema.descriptor(for: QuitBehaviorSetting.configPath) else { return }
                do { try await settings.setSetting(descriptor, to: .string(behavior.rawValue), by: .user) } catch {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
                        .error("quit setting write failed: \(String(describing: error), privacy: .public)")
                }
            },
            prepareWindows: { [steps] in
                let incognito = AgentQuitFiles.incognitoTabs(services.agentTabs, isIncognito: services.cache.browserTabs.isIncognitoTab)
                await QuitSaveSteps(
                    remoteSnapshots: { await services.remoteTerminals.saveSnapshots() },
                    agentComposers: { await services.agentTabs.relaunchWake.save(AgentQuitFiles.composers(services.agentTabs, isIncognito: incognito.contains)) },
                    agentImages: { await services.agentTabs.launchImages.save(AgentQuitFiles.images(services.agentTabs, isIncognito: incognito.contains)) },
                    terminalFrames: {
                        await TerminalLaunchFrames.beside(services.environment.sidebarSnapshotFile?.url.deletingLastPathComponent())
                            .save(services.cache.terminals.mapValues(\.session))
                    },
                    browserRecords: { await services.cache.browserTabs.flushRecords() },
                    windows: {
                        // Incognito windows' chats are purged before their spaces go (IncognitoChats), and
                        // the step waits for them: every quit, Keep included, waits for a step past its limit.
                        IncognitoChats.closingForQuit(services)
                        await services.windows.prepareForTermination()
                        await IncognitoChats.drain()
                    },
                    stopSavingWindows: { services.windows.stopSavingForTermination() },
                    sidebar: { await services.sidebarSnapshots.flush() },
                    homeCache: { await services.home.flushCacheForQuit() },
                    cloud: { await services.cloud.prepareForTermination() }
                ).run(steps)
            },
            endLocalSessions: { await services.daemon.endSessionsAndStop(choice) },
            confirmFailures: { [weak self] failures in await self?.confirm(failures) ?? .quitAnyway },
            endLocalAgents: { [attempts = QuitAttempts()] in
                // The incognito chats' purges reach acpmux before its agents end.
                await IncognitoChats.drain()
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

    /// `kAEQuitReason` of the quit Apple event being handled, if any.
    private static func quitReason() -> OSType? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return nil }
        return reason.enumCodeValue
    }
}
