/// `browser.passwords.allowExport` in cmux.json (plans/cmux-next/passwords.md 1.4, decision P3):
/// whether the Passwords page may export saved passwords to a plain text CSV file. Default off;
/// only the person may turn it on (agents are refused, `SettingsSchema.agentRefusedKeys`), and a
/// managed policy can lock it.
public nonisolated enum PasswordExportSetting {
    public static let configPath = ["browser", "passwords", "allowExport"]

    static var descriptor: SettingDescriptor {
        SettingDescriptor(
            configPath, section: .browser, group: SettingsText.keyed("settings.group.passwords", "Passwords"),
            title: SettingsText.keyed("settings.browser.passwords.allowExport", "Allow Password Export"),
            help: SettingsText.keyed("settings.browser.passwords.allowExport.help",
                                     "Export writes every saved password to a plain text file."),
            kind: .toggle, default: .bool(false), keywords: ["passwords", "export", "csv", "backup"]
        )
    }

    /// Whether export is allowed by the effective settings `root`.
    public static func isAllowed(in root: JSONValue) -> Bool {
        descriptor.effectiveValue(in: root)?.boolValue ?? false
    }
}
