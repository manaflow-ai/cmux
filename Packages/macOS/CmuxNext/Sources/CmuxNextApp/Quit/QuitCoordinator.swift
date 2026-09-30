import AppKit
import CmuxNextSettings
import os

/// Runs a quit (user decision 2026-09-30). `applicationShouldTerminate`
/// hands every quit here: it takes the origin (`QuitOriginTracker`), reads
/// the local terminals for an interactive quit, decides (`QuitPolicy`),
/// shows `QuitSheet` when asked to, then completes (`QuitCompletion`):
/// remember the choice, save and close windows, and for End end the local
/// terminals and stop the local daemon. Remote sessions are never ended.
@MainActor
final class QuitCoordinator {
    let origins = QuitOriginTracker()
    private(set) var sheet: QuitSheet?
    /// A quit is in progress (deciding, asking or completing).
    private(set) var isQuitting = false
    private unowned let services: AppServices
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")

    init(services: AppServices) {
        self.services = services
    }

    /// Records the origin, then starts AppKit's termination. A quit that is
    /// already asking or completing ignores a repeat (a second Cmd-Q).
    func requestQuit(_ origin: QuitOrigin) {
        guard !isQuitting else { return }
        origins.record(origin)
        // From a run-loop callout, not from inside the caller's main-queue
        // job (control socket, palette): terminateLater spins a nested run
        // loop, and the save Task could never get the main queue.
        RunLoop.main.perform(inModes: [.common]) {
            SheetDismissal.endAll()
            NSApp.terminate(nil)
        }
    }

    func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
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
                ask(prompt, sender)
            }
        }
        return .terminateLater
    }

    private func ask(_ prompt: QuitPrompt, _ sender: NSApplication) {
        let sheet = QuitSheet(prompt: prompt) { [weak self] answer in
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
        await QuitCompletion.run(choice, remember: remember, QuitSteps(
            remember: { behavior in
                guard let settings = services.settings,
                      let descriptor = SettingsSchema.descriptor(for: QuitBehaviorSetting.configPath) else { return }
                do { try await settings.setSetting(descriptor, to: .string(behavior.rawValue)) } catch {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
                        .error("quit setting write failed: \(String(describing: error), privacy: .public)")
                }
            },
            prepareWindows: { await services.windows.prepareForTermination() },
            endLocalSessions: { await services.daemon.endSessionsAndStop() }
        ))
        sender.reply(toApplicationShouldTerminate: true)
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
