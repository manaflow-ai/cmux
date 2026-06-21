import Foundation

extension SettingsSearchIndex {
    static var terminalScrollSpeedSettingEntries: [SettingsSearchEntry] {
        [
            setting(
                .terminal,
                "scroll-speed",
                String(localized: "settings.terminal.scrollSpeed", defaultValue: "Scroll Speed"),
                "terminal scroll speed multiplier wheel trackpad sensitivity"
            )
        ]
    }

    static var terminalScrollSpeedSettingsPathAnchorIDs: [String: String] {
        [
            "terminal.scrollSpeed": settingID(for: .terminal, idSuffix: "scroll-speed")
        ]
    }
}
