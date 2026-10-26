import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWebUpdates
import Foundation

// Launch calls that follow cmux.json: the settings controller, Home's feeds and the tagged control socket
// (`action.list/describe/run`) over the registry (task 014, see Startup+Core.swift).
extension AppDelegate {
    /// cmux-next.json settings over the registry: the web OTA check, managed policy, the palette's
    /// settings, the browser follows, the shortcut editor, the managed status report and hang reports.
    func registerSettings(services: AppServices, launch: SettingsController.LaunchRead) -> SettingsController {
        // Start the web OTA launch check before any restored or prewarmed page can
        // request its entry document. Otherwise the entry can come from the app
        // bundle while later chunks come from the kept update tree.
        WebUpdates.shared.prepare(launch.snapshot.updates, bundle: .main)
        let registry = services.registry
        let settings = SettingsController(registry: registry, fileURL: launch.fileURL, launch: launch)
        settings.applyManagedFeaturesNow()
        ManagedPolicyBridge(settings: settings, updater: services.updater, auth: services.cloudAuth).start()
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
        // Every palette-exposed schema setting in the palette (R93).
        services.palettes.sources.settings = SettingsPaletteSource(settings: settings, themes: services.themes.catalog) { [weak services] in
            services?.windows.active.map { SettingsPaletteSource.themeColors($0.themeScope.tokens) } ?? []
        }
        // Neither the first frame nor a page engine reads these (p08-startup-028).
        LaunchServicePosts.browserFollows(historyDaemonSync: { [weak services] in services?.history.startDaemonSync(settings: settings) },
                                          locationTrailScope: { [weak services] in services?.locationTrail.watchScope(settings: settings) }).post(on: order.startup)
        let shortcutEditor = PaletteShortcutEditor(services: services, settings: settings)
        services.paletteShortcutEditor = shortcutEditor  // the palette's recorder writes through it once built
        // Managed-settings status for MDM tooling (osquery, Fleet, Jamf), plans/cmux-next/enterprise.md: written on the files lane after startup.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // One sequence: each write replaces the file, so a later status must never land before an earlier one.
        let statusWrites = services.work.sequence("settings.managed-status")
        settings.writeManagedStatus(to: ManagedStatusReport.defaultURL(bundleID: bundleID),
                                    context: ManagedStatusReport.Context(appVersion: version, bundleID: bundleID)) { [startup = order.startup] write in
            startup.post(.afterStartup, "Settings.writeManagedStatus", on: .sequence(statusWrites, .bestEffort), write)
        }
        settings.start(announcingDiagnostics: true)
        AppProcessRoot.shared.hangReports?.start(settings: settings, asks: services.machineAsks, firstWindow: { [startup = order.startup] in await startup.afterFirstFrame() })
        return settings
    }

    /// The chats pager, Home's launch feeds and the GitHub feed.
    func registerHomeFeeds(services: AppServices, settings: SettingsController, acpmux: AcpmuxEnvironment?) {
        // A page's chat clicks and All chats pages work from its first frame; the feeds come after it (p08-startup-027).
        AgentPageChats.wirePager(services.agentTabs, environment: acpmux, opener: services.chatsOpener)
        services.home.postLaunchFeeds(startup: order.startup)
        // The GitHub connection is deliberately off by default. Changes in
        // Settings apply to the one feed owner and never create a second
        // inbox store.
        Task { [weak services, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await github in ObservationStream({ settings.snapshot.feedGitHub }) {
                services?.configureFeedGitHub(enabled: github.enabled, pollIntervalSeconds: github.pollIntervalSeconds)  // builds no feed
            }
        }
    }

    /// The control posts (feature `controlSocketEarlyBind`), then after the settle the settings migrations
    /// and, without that feature, the control socket.
    func registerControl(services: AppServices, settings: SettingsController) {
        // controlSocketEarlyBind: the control posts, after the first frame (p08-startup-019).
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
