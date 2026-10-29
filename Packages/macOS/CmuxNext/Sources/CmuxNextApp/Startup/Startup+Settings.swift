import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextLaunch
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextWakeups
import CmuxNextWebUpdates
import Foundation

// Launch calls that follow cmux.json: the settings controller, Home's feeds and the tagged control socket
// (`action.list/describe/run`) over the registry (task 014, see Startup+Core.swift).
extension AppDelegate {
    /// cmux-next.json settings over the registry: the web OTA check, the managed status report, managed policy,
    /// the palette's settings and shortcut editor, the browser follows, the file watches and hang reports.
    func registerSettings(services: AppServices, launch: SettingsController.LaunchRead) -> SettingsController {
        // The web OTA launch check (kept update read in `main`) before any page asks for its entry document, else the
        // entry can come from the bundle and later chunks from the update; the network check waits for startup complete.
        WebUpdates.shared.prepare(launch.snapshot.updates, launch: environment.webUpdates, inputs: WebUpdates.Inputs(
            files: services.work, energy: services.mainWork.energy, shown: services.features.isEnabled(.hiddenPollPause) ? services.appVisibility.shownWindows : nil,
            deadlines: services.mainDeadlines, appEvents: services.appEvents, checkNode: services.appVisibility.node),
            pages: { [weak services] in services?.webUI })
        order.startup.post(.afterStartup, "WebUpdates.startChecks", on: .main) { WebUpdates.shared.startChecks() }
        let registry = services.registry
        let settings = SettingsController(registry: registry, fileURL: launch.fileURL, launch: launch, mainWork: services.mainWork)
        // Managed-settings status for MDM tooling (osquery, Fleet, Jamf), plans/cmux-next/enterprise.md: written on the files lane after startup.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // One sequence: each write replaces the file, so a later status must never land before an earlier one.
        let statusWrites = services.work.sequence("settings.managed-status")
        settings.writeManagedStatus(to: ManagedStatusReport.defaultURL(bundleID: bundleID),
                                    context: ManagedStatusReport.Context(appVersion: version, bundleID: bundleID)) { [startup = order.startup] write in
            startup.post(.afterStartup, "Settings.writeManagedStatus", on: .sequence(statusWrites, .bestEffort), write)
        }
        settings.applyManagedFeaturesNow()
        settings.adoptLaunchRead()  // the first load from the launch read, no file call: the first frame is in the file's look
        services.lifetimeFollowers += ManagedPolicyBridge(settings: settings, updater: services.updater, auth: services.cloudAuth, mainWork: services.mainWork, appEvents: services.appEvents).start()
        self.settings = settings
        services.settings = settings
        // No socket write asks for a confirmation before the first frame: the control socket starts after it.
        order.startup.post(.afterFirstFrame, "UserOnlySettingConfirmation.install", on: .main) { [weak settings, weak services] in
            if let settings, let services { UserOnlySettingConfirmation.install(settings, services: services) }
        }
        // macOS posts no notification when an MDM profile changes: activation is the backstop next to the managed-file watchers.
        order.startup.post(.afterFirstFrame, "Settings.followActivation", on: .main) { [weak settings, events = services.appEvents] in
            settings?.followActivation(on: events)
        }
        // Every palette-exposed schema setting in the palette (R93), and the recorder's writes; neither builds the palette.
        order.startup.post(.afterFirstFrame, "Palette.settingsSource", on: .main) { [weak services, weak settings] in
            guard let services, let settings else { return }
            services.palettes.sources.settings = SettingsPaletteSource(
                settings: settings, themes: services.themes.catalog,
                availability: { [weak services] in services?.settingsAvailability ?? SettingsAvailability() }
            ) { [weak services] in
                services?.windows.active.map { SettingsPaletteSource.themeColors($0.themeScope.tokens) } ?? []
            }
            services.paletteShortcutEditor = PaletteShortcutEditor(services: services, settings: settings)
        }
        // Neither the first frame nor a page engine reads these.
        LaunchServicePosts.browserFollows(historyDaemonSync: { [weak services] in services?.history.startDaemonSync(settings: settings) },
                                          locationTrailScope: { [weak services] in services?.locationTrail.watchScope(settings: settings) }).post(on: order.startup)
        // The file watches and the diagnostic toasts; the launch read is applied above, and the start reloads once.
        let diagnosticPresenter = SettingsDiagnosticToastPresenter(events: services.appEvents, toasts: .shared)
        // A diagnostic's Show in Settings follows the same availability as the page and `openSettings`.
        order.startup.post(.afterFirstFrame, "Settings.start", on: .main) { [weak settings, weak services, diagnosticPresenter] in
            settings?.start(announcingDiagnostics: diagnosticPresenter,
                            availability: { [weak services] in services?.settingsAvailability ?? SettingsAvailability() })
        }
        AppProcessRoot.shared.hangReports?.recordUserWrites(of: settings)  // the person's own consent, from the first write on
        order.startup.post(.afterStartup, "HangReports.start", on: .main) { [weak settings, asks = services.machineAsks, startup = order.startup] in
            if let settings { AppProcessRoot.shared.hangReports?.start(settings: settings, asks: asks, firstWindow: { await startup.afterFirstFrame() }) }
        }
        return settings
    }

    /// `launch.savedPicture` off deletes the saved window pictures at once, not at the next quit (p08-startup 3C).
    func registerSavedPicture(services: AppServices, settings: SettingsController) {
        guard let pictures = services.environment.windowPictures else { return }
        services.lifetimeFollowers.append(pictures.followSavedPicture({
            settings.loadCount >= 1 ? settings.snapshot.savedPicture : nil
        }, on: services.mainWork))
    }

    /// The chat settings push and chats pager once acpmux resolves, Home's launch feeds and the GitHub feed.
    func registerHomeFeeds(services: AppServices, settings: SettingsController) {
        // Once main's acpmux resolve lands (now, unless its signature check still runs on the system lane): an
        // attached daemon (`CMUX_NEXT_ACPMUX_ATTACH`) keeps its owner's chat settings; a page's chat clicks and All
        // chats pages work from then; the feeds come after the first frame.
        QuitAgents.whenResolved(services, owner: "launch.acpmuxChats") { [weak services] acpmux in
            guard let services else { return }
            services.lifetimeFollowers += ChatSettingsPush.start(settings: settings, socketPath: acpmux?.isAttached == true ? nil : acpmux?.socketPath,
                                                                 on: services.mainWork)
            AgentPageChats.wirePager(services.agentTabs, environment: acpmux, opener: services.chatsOpener)
        }
        services.home.postLaunchFeeds(startup: order.startup)
        // The GitHub connection is deliberately off by default. Changes in
        // Settings apply to the one feed owner and never create a second
        // inbox store.
        order.startup.post(.afterStartup, "FeedGitHub.follow", on: .main) { [weak services, weak settings] in
            guard let services, let settings else { return }
            services.lifetimeFollowers.append(ServiceObservation(.background, owner: "FeedGitHub.setting", on: services.mainWork) {
                settings.snapshot.feedGitHub
            } apply: { [weak services] github in
                services?.configureFeedGitHub(enabled: github.enabled, pollIntervalSeconds: github.pollIntervalSeconds)  // builds no feed
            })
        }
    }

    /// The control posts (feature `controlSocketEarlyBind`), then after the settle the settings migrations
    /// and, without that feature, the control socket.
    func registerControl(services: AppServices, settings: SettingsController) {
        // controlSocketEarlyBind: the control posts, after the first frame.
        control.postLaunch(socket: controlSocket, order: order, services: services, settings: settings, launch: environment.launch, logger: logger)
        Task {
            await settings.waitForLoad(atLeast: 1); await launchSettle.settled(within: .seconds(4), images: launchImageHold) // without controlSocketEarlyBind, the control socket starts here (cx-z9kz0)
            // `app.quitBehavior: "end"` (first release) is now "end-keep-layout".
            _ = try? await settings.migrateLegacyQuitBehavior()
            _ = try? await settings.migrateLegacyWorkspaceRowKeys() // `sidebar.showWorkspaceDirectory` / `showCounts` move to `sidebar.workspaceRow.*`
            _ = try? await settings.migrateLegacyPaneToolbarButtons() // `tabs.hiddenButtons` becomes `tabs.toolbarButtons`
            // Classic cmux keys next reads under another name (`ClassicSettingRename`).
            _ = try? await settings.migrateClassicSettings()
            // Shortcuts and settings classic cmux's Settings kept in its preferences (`ClassicShortcutImport`, `ClassicPreferenceImport`).
            _ = try? await settings.importClassicShortcuts(marker: .standard)
            _ = try? await settings.importClassicPreferences(marker: .standard)
            control.runAfterSettle(socket: controlSocket, services: services, settings: settings, launch: environment.launch, logger: logger)
        }
    }
}
