import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextUpdater
import CmuxNextWakeups
import CmuxNextWebUpdates

extension UpdaterService {
    /// Wires the updater to the App in `AppServices.init`: the sheet (failure details, managed
    /// policy, required version), and a relaunch into an update that keeps
    /// every terminal and agent (no quit sheet; the footer pill's tooltip
    /// says so, SIDEBAR-FOOTER-MINIMAL). `simulating` is Debug Settings
    /// "Simulate pending update" (DEV and NIGHTLY; elsewhere it stays off).
    /// Closures and the What's New record only, so the first frame's cards
    /// (Updated, tips) and their links work; the reads are `startAttachedWork()`.
    func wire(sheet: UpdateSheetController, services: AppServices, simulating: @escaping @MainActor @Sendable () -> Bool) {
        presentUpdateUI = { [weak services] in sheet.present(in: services?.windows.active?.window) }
        willRelaunch = { [weak services] in services?.quit.origins.record(.explicit(.keep)) }
        relaunchBlockers = { [weak self, weak services, activity = UpdateAgentActivity(environment: QuitAgents.environment(services), mainWork: services.mainWork, runner: services.work)] in services.map { activity.applying(to: $0.machines.local.currentRelaunchBlockers(quietInput: self?.idleInstallQuiet)) } ?? .daemonUnavailable }
        // The click: the windows leave the screen at once (S1); a failed
        // install brings them back.
        let handoff = UpdateWindowHandoff(unsaved: services.quitUnsaved)
        willInstallStaged = { _ = handoff.hide() }
        installAbandoned = { handoff.restore() }
        isSheetPresented = { sheet.isPresented }
        sheet.onDismiss = { [weak self] in self?.updateSheetClosed() }
        // The check's progress and result show on the sidebar's notice card; with the
        // active window's sidebar hidden (or no window) nothing would show, so the sheet
        // answers instead (never a check with no visible feedback).
        showsIndicator = { [weak services] in (services?.windows.active).map { !$0.state.sidebarHidden } ?? false }
        openChangelog = { [weak services] in services.map { ChangelogPageTab.open($0) } ?? false }
        // "See What's New" on the Updated card: the React changelog page
        // for the releases this update crossed (`#/?from=&to=`).
        openChangelogSpan = { [weak services] from, to in services.map { ChangelogPageTab.open($0, from: from, to: to) } ?? false }
        openReleaseNotesURL = { [weak services] url in
            guard let services, url.scheme == "https" else { return false }
            SidebarCardFeed.openUpdateLink(url, services: services)
            return true
        }
        // What's New after an update: the record (UserDefaults) decides the first frame's
        // Updated card; the bundled documents and this feed's digests load in its task.
        whatsNew.load()
        runAllowListedAction = { [weak services] id in
            guard PageDescriptor.changelogTryItActions.contains(id) else { return }
            _ = services?.registry.perform(ActionID(rawValue: id), invocation: ActionInvocation(origin: .user))
        }
        wireTips(registry: services.registry)
        UpdateSimulation(updater: self).follow(simulating)
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarnessProbe.install(updater: self, mainWork: services.mainWork, appEvents: services.appEvents)
        #endif
    }

    /// The work behind the wired cards, after startup (the `Updater.attachedWork` launch post):
    /// the Updated card's change list when its record has none (2026-10-20; a network read), and the
    /// tip's re-pick when cmux becomes active again.
    func startAttachedWork(appEvents: AppEvents) {
        loadCurrentBuildNotesIfNeeded()
        refreshTipOnActivation(on: appEvents)
    }

    /// The tips card (BOTTOM-LEFT-CARDS K1): "Try It" runs the catalog
    /// action as the user's own; the user's own runs mark features used
    /// (local only). A return to cmux may pick the next day's tip (`startAttachedWork()`).
    func wireTips(registry: ActionRegistry) {
        runTipAction = { [weak registry] action in
            guard TipCatalog.all.contains(where: { $0.action == action }) else { return }
            _ = registry?.perform(ActionID(rawValue: action), invocation: ActionInvocation(origin: .user))
        }
        registry.runObserver = { [weak self] id, invocation in
            guard invocation.origin == .user else { return }
            self?.markTipActionUsed(id.rawValue)
        }
    }

    /// Follows `updates.*` in cmux.json (R114): the gate's preferences and
    /// Sparkle's schedule and download behavior. One ServiceObservation on `mainWork`: the values
    /// apply now once the settings loaded (before `Updater.start`), else at the first load, and each
    /// batch of changes applies once, in a posted task.
    func follow(_ settings: SettingsController, on mainWork: MainWorkScheduler) {
        settingsObservation?.cancel()
        // The update card's Automatic Updates box and the tip card's Never Show Tips write the
        // same settings as Settings (UPDATE-CARD); the change returns through the observation below.
        writeSetting = { [weak self, weak settings] setting, on in
            guard let settings else { return }
            let log = self?.log, path = setting == .tips ? SidebarSectionsSetting.tipsPath : UpdatesSettings.downloadAutomaticallyPath
            // task-owner: one settings write that ends by itself; nothing to cancel. Off main until the controller's write.
            Task { @concurrent in
                do {
                    try await settings.setSetting(at: path, to: .bool(on), by: .user)
                } catch {
                    log?.append("\(path.joined(separator: ".")) not written: \(error)")
                }
            }
        }
        settingsObservation = ServiceObservation(.visible, owner: "UpdaterService.settings", on: mainWork) { [weak settings] in
            guard let settings, settings.loadCount > 0 else { return }
            _ = (settings.snapshot.updates, settings.snapshot.announcements, settings.snapshot.sidebarSections.showsTips)
        } apply: { [weak self, weak settings] _ in
            guard let self, let settings, settings.loadCount > 0 else { return }
            followed(settings.snapshot)
        }
    }

    /// Applies the `updates.*`, `announcements.*` and tips settings of `snapshot`.
    private func followed(_ snapshot: CmuxConfigSnapshot) {
        let updates = snapshot.updates, announcements = snapshot.announcements, tips = snapshot.sidebarSections.showsTips
        apply(updates)
        if whatsNew.isItemEnabled != updates.showWhatsNew { whatsNew.isItemEnabled = updates.showWhatsNew }
        if tipsEnabled != tips { tipsEnabled = tips }
        announcementsFetch = announcements.fetch
        if announcementsEnabled != announcements.enabled { announcementsEnabled = announcements.enabled }
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
