import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextUpdater
import CmuxNextWebUpdates
import Observation

extension UpdaterService {
    /// Wires the updater to the App: the sheet (failure details, managed
    /// policy, required version), and a relaunch into an update that keeps
    /// every terminal and agent (no quit sheet; the footer pill's tooltip
    /// says so, SIDEBAR-FOOTER-MINIMAL). `simulating` is Debug Settings
    /// "Simulate pending update" (DEV and NIGHTLY; elsewhere it stays off).
    func attach(sheet: UpdateSheetController, services: AppServices, simulating: @escaping @MainActor @Sendable () -> Bool) {
        presentUpdateUI = { [weak services] in sheet.present(in: services?.windows.active?.window) }
        relaunchBehind = { [weak services] willQuit, declined, inFront in
            let behind = UpdateRelaunchBehind(app: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            // A quit the user refuses (a quit dialog's Cancel) stops the helper and stages the update again.
            services?.quit.onQuitRefused = { behind.quitRefused() }
            behind.start(willQuit: willQuit, declined: declined, inFront: inFront)
        }
        relaunchBlockers = { [weak self, weak services, activity = UpdateAgentActivity(environment: QuitAgents.environment(services))] in services.map { activity.applying(to: $0.machines.local.currentRelaunchBlockers(quietInput: self?.idleInstallQuiet)) } ?? .daemonUnavailable }
        // The windows leave the screen when Sparkle commits to the relaunch,
        // not at the click (`UpdateWindowHandoff`); a failed install brings them back.
        let handoff = UpdateWindowHandoff(unsaved: services.quitUnsaved)
        willRelaunch = { [weak services] in services?.quit.origins.record(.explicit(.keep)) }
        hidesForRelaunch = { _ = handoff.hide() }
        installAbandoned = { handoff.restore() }
        isSheetPresented = { sheet.isPresented }
        sheet.onDismiss = { [weak self] in self?.updateSheetClosed() }
        // The check's progress and result show on the sidebar's notice card; with the
        // active window's sidebar hidden (or no window) nothing would show, so the sheet
        // answers instead (never a check with no visible feedback).
        showsIndicator = { [weak services] in (services?.windows.active).map { !$0.state.sidebarHidden } ?? false }
        openChangelog = { [weak services] in
            return services.map { ChangelogPageTab.open($0) } ?? false
        }
        // "See What's New" on the Updated card: the React changelog page
        // for the releases this update crossed (`#/?from=&to=`).
        openChangelogSpan = { [weak services] from, to in
            return services.map { ChangelogPageTab.open($0, from: from, to: to) } ?? false
        }
        openReleaseNotesURL = { [weak services] url in
            guard let services, url.scheme == "https" else { return false }
            SidebarCardFeed.openUpdateLink(url, services: services)
            return true
        }
        // What's New shows after every update unless `updates.showWhatsNew` is turned off (user 13935: no Labs gate).
        whatsNew.isItemEnabled = services.settings?.snapshot.updates.showWhatsNew != false
        // What's New after an update: bundled documents and this feed's digests.
        whatsNew.load()
        // The Updated card's change list when the update record has none (2026-10-20).
        loadCurrentBuildNotesIfNeeded()
        runAllowListedAction = { [weak services] id in
            guard PageDescriptor.changelogTryItActions.contains(id) else { return }
            _ = services?.registry.perform(ActionID(rawValue: id), invocation: ActionInvocation(origin: .user))
        }
        attachTips(registry: services.registry)
        UpdateSimulation(updater: self).follow(simulating)
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarnessProbe.install(updater: self)
        #endif
    }

    /// The tips card (BOTTOM-LEFT-CARDS K1): "Try It" runs the catalog
    /// action as the user's own; the user's own runs mark features used
    /// (local only); a return to cmux may pick the next day's tip.
    func attachTips(registry: ActionRegistry) {
        runTipAction = { [weak registry] action in
            guard TipCatalog.all.contains(where: { $0.action == action }) else { return }
            _ = registry?.perform(ActionID(rawValue: action), invocation: ActionInvocation(origin: .user))
        }
        registry.runObserver = { [weak self] id, invocation in
            guard invocation.origin == .user else { return }
            self?.markTipActionUsed(id.rawValue)
        }
        refreshTipOnActivation()
    }

    /// Follows `updates.*` in cmux.json (R114): the gate's preferences and
    /// Sparkle's schedule and download behavior.
    func follow(_ settings: SettingsController) {
        settingsObservation?.cancel()
        // The update card's Automatic Updates box and the tip card's Never Show Tips write the
        // same settings as Settings (UPDATE-CARD); the change returns through the observation below.
        writeSetting = { [weak self, weak settings] setting, on in
            guard let settings else { return }
            let log = self?.log, path = setting == .tips ? SidebarSectionsSetting.tipsPath : UpdatesSettings.downloadAutomaticallyPath
            // task-owner: one settings write that ends by itself; nothing to cancel.
            Task { @MainActor in
                do {
                    try await settings.setSetting(at: path, to: .bool(on), by: .user)
                } catch {
                    log?.append("\(path.joined(separator: ".")) not written: \(error)")
                }
            }
        }
        settingsObservation = Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await (updates, announcements, tips, _) in ObservationStream({
                (settings.snapshot.updates, settings.snapshot.announcements, settings.snapshot.sidebarSections.showsTips, settings.snapshot.previewFeatures)
            }) {
                self?.apply(updates)
                let whatsNewEnabled = updates.showWhatsNew
                if self?.whatsNew.isItemEnabled != whatsNewEnabled { self?.whatsNew.isItemEnabled = whatsNewEnabled }
                if self?.whatsNew.isItemEnabledKnown == false { self?.whatsNew.isItemEnabledKnown = true }
                if self?.tipsEnabled != tips { self?.tipsEnabled = tips }
                self?.announcementsFetch = announcements.fetch
                if self?.announcementsEnabled != announcements.enabled { self?.announcementsEnabled = announcements.enabled }
            }
        }
    }

    func apply(_ updates: UpdatesSettings) {
        WebUpdates.shared.follow(updates)
        let preferences = UpdatePreferences(
            installOnQuit: updates.installOnQuit,
            notify: UpdateNotifyMode(rawValue: updates.notify.rawValue) ?? .badge,
            keepPreviousVersions: updates.keepPreviousVersions)
        if self.preferences != preferences { self.preferences = preferences }
        configure(checkAutomatically: updates.checkAutomatically, checkInterval: updates.checkIntervalSeconds,
                  downloadAutomatically: updates.downloadAutomatically,
                  metered: UpdateMeteredMode(rawValue: updates.meteredNetwork.rawValue) ?? .deferLowData, ring: updates.channel.rawValue, idleInstall: (updates.idleInstallMaxWaitSeconds, updates.idleInstallQuietSeconds))
    }
}
