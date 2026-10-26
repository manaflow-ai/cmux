import AppKit
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWebUpdates
import os

// Launch calls for cmux.json's launch read and the settings controller (task 014, see Startup+Core.swift).
extension AppDelegate {
    /// cmux.json's launch read, before the theme and the services.
    func registerSettingsRead() -> SettingsController.LaunchRead {
        // cmux.json's appearance goes on the Ghostty overrides before the
        // runtime's first config load, so the first frame needs no reload.
        let settingsRead = SettingsController.readAtLaunch(fileURL: settingsFileURL())
        TerminalThemeSetting.prime(settingsRead.snapshot)
        return settingsRead
    }

    /// cmux-next.json settings over the registry: the web OTA check, managed policy, the palette's
    /// settings, the shortcut editor, the managed status report and hang reports.
    func registerSettings(services: AppServices, launch: SettingsController.LaunchRead) -> SettingsController {
        // Start the web OTA launch check before any restored or prewarmed page can
        // request its entry document. Otherwise the entry can come from the app
        // bundle while later chunks come from the kept update tree.
        WebUpdates.shared.prepare(launch.snapshot.updates, bundle: .main)
        let settings = SettingsController(registry: services.registry, fileURL: launch.fileURL, launch: launch)
        settings.applyManagedFeaturesNow()
        ManagedPolicyBridge(settings: settings, updater: services.updater, auth: services.cloud.auth).start()
        self.settings = settings
        services.settings = settings
        UserOnlySettingConfirmation.install(settings, services: services)
        // Every palette-exposed schema setting in the palette (R93).
        services.palette.sources.settings = SettingsPaletteSource(settings: settings, themes: services.themes.catalog) { [weak services] in
            services?.windows.active.map { SettingsPaletteSource.themeColors($0.themeScope.tokens) } ?? []
        }
        services.history.startDaemonSync(settings: settings)
        services.locationTrail.watchScope(settings: settings)
        let shortcutEditor = PaletteShortcutEditor(services: services, settings: settings)
        services.paletteShortcutEditor = shortcutEditor
        services.palette.shortcutRecorder.editor = shortcutEditor
        // Managed-settings status for MDM tooling (osquery, Fleet, Jamf), plans/cmux-next/enterprise.md.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        settings.writeManagedStatus(
            to: ManagedStatusReport.defaultURL(bundleID: bundleID),
            context: ManagedStatusReport.Context(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                bundleID: bundleID
            )
        )
        settings.start(announcingDiagnostics: true)
        AppProcessRoot.shared.hangReports?.start(settings: settings, asks: services.machineAsks, firstWindow: { [firstFrame] in await firstFrame.opened() })
        return settings
    }

    /// The managed-preferences watch on app activation.
    func registerManagedPreferencesWatch(settings: SettingsController) {
        // macOS posts no notification when an MDM profile changes; activation
        // is the event-driven backstop next to the managed-file watchers.
        Task { [weak settings] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                settings?.managedPreferencesMayHaveChanged()
            }
        }
    }

    /// cmux.json, created on first launch.
    private func settingsFileURL() -> URL {
        do {
            return try CmuxConfigFile.prepareDefaultURL()
        } catch {
            logger.error("cmux-next config bootstrap failed: \(String(describing: error), privacy: .public)")
            return CmuxConfigFile.defaultURL()
        }
    }
}
