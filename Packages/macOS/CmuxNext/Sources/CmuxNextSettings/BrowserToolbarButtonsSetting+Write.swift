import os

extension BrowserToolbarButtonsSetting {
    /// Pins or unpins button `id` in cmux.json for the person (the More
    /// menu's Show in Toolbar, `SettingWriter.currentRun`); every toolbar
    /// follows the file. A second toggle before the first write lands builds
    /// on the first, not on the old file.
    @MainActor public static func toggle(_ id: String, in settings: SettingsController) {
        let next = (pending ?? current(settings)).toggling(id)
        pending = next
        // task-owner: one write; the menu item's gesture is the user's (SettingWriter.currentRun)
        // main-hop-allow: an inherited Task keeps the menu run's task locals, which `.currentRun()` reads to name the
        // writer (a detached one would write as nobody); setSetting is the controller's main-actor async write
        Task {
            defer { if pending == next { pending = nil } }
            do {
                try await settings.setSetting(at: configPath, to: next.configValue, by: .currentRun())
            } catch {
                logger.error("browser.toolbarButtons write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Whether a managed value (MDM, team policy) decides the list; then the
    /// menu shows it and does not change it.
    @MainActor public static func isManaged(in settings: SettingsController) -> Bool {
        settings.managedKeys[configPath.joined(separator: ".")] != nil
    }

    /// What the More menu's Show in Toolbar rows need: whether they are
    /// enabled (not managed) and the toggle by button id. Nil settings (not
    /// loaded yet): disabled rows.
    @MainActor public static func menuToggle(_ settings: SettingsController?) -> (enabled: Bool, toggle: (String) -> Void) {
        guard let settings else { return (false, { _ in }) }
        return (!isManaged(in: settings), { [weak settings] id in settings.map { toggle(id, in: $0) } })
    }

    /// The list the last toggle wrote, until its write lands.
    @MainActor private static var pending: BrowserToolbarButtonsSetting?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser-toolbar")
}
