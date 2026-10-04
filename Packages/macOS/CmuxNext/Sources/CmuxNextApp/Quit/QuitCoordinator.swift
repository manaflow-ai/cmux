import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import os

/// Runs a quit (user decision 2026-09-30). `applicationShouldTerminate`
/// hands every quit here: it takes the origin (`QuitOriginTracker`), reads
/// the local terminals for an interactive quit, decides (`QuitPolicy`),
/// shows `QuitAlert` when asked to, then completes (`QuitCompletion`):
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
    /// The last dialog brought the app forward (`debug.quit`).
    private(set) var lastAskActivated = false
    private unowned let services: AppServices
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")

    init(services: AppServices) {
        self.services = services
    }

    /// Records the origin, then starts AppKit's termination. A second Cmd-Q
    /// while the dialog asks confirms its default (keep) on the first step
    /// and does nothing on the confirmation; a quit already completing
    /// ignores a repeat.
    func requestQuit(_ origin: QuitOrigin) {
        guard !isQuitting else {
            if origin == .interactive { sheet?.answerDefault() }
            return
        }
        origins.record(origin)
        // From a run-loop callout, not from inside the caller's main-queue
        // job (control socket, palette): terminateLater spins a nested run
        // loop, and the save Task could never get the main queue.
        RunLoop.main.perform(inModes: [.common]) {
            SheetDismissal.endAll()
            NSApp.terminate(nil)
        }
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
        // Quit (menu, Cmd-Q, socket) never waits on another open sheet.
        SheetDismissal.endAll()
        let origin = origins.consume(appleEventReason: Self.quitReason())
        let behavior = services.settings?.snapshot.quitBehavior ?? QuitBehaviorSetting.fallback
        logger.info("quit origin=\(String(describing: origin), privacy: .public) behavior=\(behavior.rawValue, privacy: .public)")
        Task { @MainActor in
            let facts = QuitPolicy.needsFacts(origin) ? await QuitFactsReader.read(services) : .none
            switch QuitPolicy.decide(origin, behavior: behavior, facts: facts) {
            case .quit(let choice):
                await complete(choice, remember: false, sender)
            case .ask(let prompt):
                ask(prompt, sender, activate: Self.shouldActivate(origin, isActive: NSApp.isActive,
                                                                  noActivate: WindowPlacement.noActivate))
            }
        }
        return .terminateLater
    }

    /// A quit from the Dock or the app switcher while cmux is inactive is the
    /// user's: cmux comes forward so the dialog is seen. Never in a
    /// no-activate launch; non-interactive quits never ask.
    static func shouldActivate(_ origin: QuitOrigin, isActive: Bool, noActivate: Bool) -> Bool {
        origin == .interactive && !isActive && !noActivate
    }

    private func ask(_ prompt: QuitPrompt, _ sender: NSApplication, activate: Bool) {
        lastAskActivated = activate
        if activate { NSApp.activate() }
        let sheet = QuitAlert(prompt: prompt) { [weak self] answer in
            guard let self else { return }
            self.sheet = nil
            switch answer {
            case .cancel:
                self.isQuitting = false
                sender.reply(toApplicationShouldTerminate: false)
            case .quit(let choice, let remember):
                Task { @MainActor in await self.complete(choice, remember: remember, sender) }
            }
        }
        self.sheet = sheet
        sheet.present(in: sheetWindow())
    }

    private func complete(_ choice: QuitSessionsChoice, remember: Bool, _ sender: NSApplication) async {
        logger.info("quit choice=\(choice.rawValue, privacy: .public) remember=\(remember)")
        let services = services
        // From here the quit is decided: an end before AppKit's reply (a
        // SIGKILL after a bounded wait, a slow Chromium shutdown) is still
        // a quit the user asked for, not a crash.
        // Awaited (bounded) so `quitting` is on disk before the quit can end
        // the process; the write itself runs off the main thread.
        await services.crashRecovery.quitBegan()
        await QuitCompletion.run(choice, remember: remember, QuitSteps(
            remember: { behavior in
                guard let settings = services.settings,
                      let descriptor = SettingsSchema.descriptor(for: QuitBehaviorSetting.configPath) else { return }
                do { try await settings.setSetting(descriptor, to: .string(behavior.rawValue)) } catch {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
                        .error("quit setting write failed: \(String(describing: error), privacy: .public)")
                }
            },
            prepareWindows: {
                // Remote-terminal tabs keep their last screen for the
                // placeholder after relaunch (data-model.md 1.4).
                await services.remoteTerminals.saveSnapshots()
                // Browser tabs reopen at their recorded page (before any
                // session ends, while the daemon still answers).
                await services.cache.browserTabs.flushRecords()
                await services.windows.prepareForTermination()
                await services.sidebarSnapshots.flush()
            },
            endLocalSessions: { await services.daemon.endSessionsAndStop($0) },
            confirmFailures: { [weak self] failures in await self?.confirm(failures) ?? .quitAnyway },
            endLocalAgents: { await QuitAgents.end(QuitAgents.environment(services)) },
            stopBrowserEngines: { await services.cache.cef.shutdown() }
        ))
        sender.reply(toApplicationShouldTerminate: true)
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
        let candidates = [services.windows.active?.window, NSApp.mainWindow] + services.windows.controllers.map(\.window)
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
