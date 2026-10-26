import CmuxNextSettings

// Launch calls for the tagged control socket (`action.list/describe/run`) over the registry (task 014,
// see Startup+Core.swift).
extension AppDelegate {
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
