public import CmuxNextSettings

extension UpdaterService {
    /// The update card's Automatic Updates box and the tip card's Never Show Tips write the same settings as
    /// Settings (UPDATE-CARD), as the person (``writeSetting``); the change returns through the settings
    /// observation. (Moved here from the App's updater wiring.)
    public func writesSettings(to settings: SettingsController) {
        writeSetting = { [weak self, weak settings] setting, on in
            guard let settings else { return }
            let log = self?.log, path = setting == .tips ? SidebarSectionsSetting.tipsPath : UpdatesSettings.automaticPath
            // The card's box is Automatic Updates' download step: on downloads (Install When Idle stays as
            // it is), off asks first (Notify Only).
            // task-owner: one settings write that ends by itself; nothing to cancel.
            Task { @MainActor in
                let current = settings.snapshot.updates.automatic
                let value: JSONValue = setting == .tips ? .bool(on)
                    : .string((on ? (current == .idle ? .idle : .download) : UpdatesAutomaticSetting.notify).rawValue)
                do {
                    try await settings.setSetting(at: path, to: value, by: .user)
                } catch {
                    log?.append("\(path.joined(separator: ".")) not written: \(error)")
                }
            }
        }
    }
}
