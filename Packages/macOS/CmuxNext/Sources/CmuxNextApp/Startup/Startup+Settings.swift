import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWebUpdates
import Foundation

// Launch calls for cmux.json's settings controller (task 014, see Startup+Core.swift).
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
}
