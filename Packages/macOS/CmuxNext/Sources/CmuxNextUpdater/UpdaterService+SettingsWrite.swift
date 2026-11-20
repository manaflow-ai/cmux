public import CmuxNextSettings

extension UpdaterService {
    /// The update card's Automatic Updates box and the tip card's Never Show Tips write the same settings as
    /// Settings (UPDATE-CARD), as the person (``writeSetting``); the change returns through the settings
    /// observation. (Moved here from the App's updater wiring.)
    public func writesSettings(to settings: SettingsController) {
        writeSetting = { [weak self, weak settings] setting, on in
            guard let settings else { return }
            let log = self?.log
            // Disable installation first. Enable it last, after downloads were successfully enabled.
            // Each write uses the validated user settings path, including managed-policy checks.
            let paths = setting == .tips ? [SidebarSectionsSetting.tipsPath] :
                (on ? [UpdatesSettings.downloadAutomaticallyPath, UpdatesSettings.installWhenIdlePath] :
                    [UpdatesSettings.installWhenIdlePath, UpdatesSettings.downloadAutomaticallyPath])
            // Serialize rapid clicks so the two preferences finish in click order.
            let previous = self?.settingsWriteTask
            // task-owner: finite settings writes, retained until the next write.
            self?.settingsWriteTask = Task {
                await previous?.value
                for path in paths {
                    do {
                        try await settings.setSetting(at: path, to: .bool(on), by: .user)
                    } catch {
                        log?.append("\(path.joined(separator: ".")) not written: \(error)")
                        // Enabling installs requires a successful download write. Disabling keeps
                        // going so a managed install policy cannot prevent the download opt-out.
                        if on { break }
                    }
                }
            }
        }
    }
}
