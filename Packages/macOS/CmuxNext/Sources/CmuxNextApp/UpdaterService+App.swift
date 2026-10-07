import CmuxNextActions
import CmuxNextPages
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextUpdater
import Observation

extension UpdaterService {
    /// Wires the updater to the App: the sheet (failure details, managed
    /// policy, required version), and a relaunch into an update that keeps
    /// every terminal and agent (no quit sheet; the footer pill's tooltip
    /// says so, SIDEBAR-FOOTER-MINIMAL).
    func attach(sheet: UpdateSheetController, services: AppServices) {
        presentUpdateUI = { [weak services] in sheet.present(in: services?.windows.active?.window) }
        willRelaunch = { [weak services] in services?.quit.origins.record(.explicit(.keep)) }
        isSheetPresented = { sheet.isPresented }
        openChangelog = { [weak services] in services.map { ChangelogPageTab.open($0) } ?? false }
        // What's New after an update: bundled documents and this feed's digests.
        whatsNew.load()
        runAllowListedAction = { [weak services] id in
            guard PageDescriptor.changelogTryItActions.contains(id) else { return }
            _ = services?.registry.perform(ActionID(rawValue: id), invocation: ActionInvocation(origin: .user))
        }
    }

    /// Follows `updates.*` in cmux.json (R114): the gate's preferences and
    /// Sparkle's schedule and download behavior.
    func follow(_ settings: SettingsController) {
        settingsObservation?.cancel()
        // The update card's Automatic Updates box writes the same setting
        // as Settings > General (UPDATE-CARD); the change returns through
        // the observation below.
        writeAutomaticUpdates = { [weak self, weak settings] on in
            guard let settings else { return }
            let log = self?.log
            // task-owner: one settings write that ends by itself; nothing to cancel.
            Task { @MainActor in
                do {
                    try await settings.setSetting(at: UpdatesSettings.downloadAutomaticallyPath, to: .bool(on), by: .user)
                } catch {
                    log?.append("automatic updates not written: \(error)")
                }
            }
        }
        settingsObservation = Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await (updates, announcements) in Observations({ (settings.snapshot.updates, settings.snapshot.announcements) }) {
                self?.apply(updates)
                if self?.whatsNew.isItemEnabled != updates.showWhatsNew { self?.whatsNew.isItemEnabled = updates.showWhatsNew }
                self?.announcementsFetch = announcements.fetch
                if self?.announcementsEnabled != announcements.enabled { self?.announcementsEnabled = announcements.enabled }
            }
        }
    }

    func apply(_ updates: UpdatesSettings) {
        let preferences = UpdatePreferences(
            installOnQuit: updates.installOnQuit,
            notify: UpdateNotifyMode(rawValue: updates.notify.rawValue) ?? .badge,
            keepPreviousVersions: updates.keepPreviousVersions)
        if self.preferences != preferences { self.preferences = preferences }
        configure(checkAutomatically: updates.checkAutomatically, checkInterval: updates.checkIntervalSeconds,
                  downloadAutomatically: updates.downloadAutomatically,
                  metered: UpdateMeteredMode(rawValue: updates.meteredNetwork.rawValue) ?? .deferLowData)
    }
}
