/// The iMessage connector's persisted choices. The connector is visible by default;
/// reading Messages starts only after the person's Connect click enables it.
nonisolated extension CmuxConfigSnapshot {
    public static let imessageEnabledPath = ["imessage", "enabled"]
    public static let imessageAutomationSkippedPath = ["imessage", "automationSkipped"]
    public static let imessageEnabledDefault = false
    public static let imessageAutomationSkippedDefault = false

    /// The one opt-in shared by the app and the daemon; invalid values never enable reads.
    public var imessageEnabled: Bool {
        root.value(at: Self.imessageEnabledPath)?.boolValue ?? Self.imessageEnabledDefault
    }

    /// The walkthrough choice only; it grants neither Messages access nor permission to send.
    public var imessageAutomationSkipped: Bool {
        root.value(at: Self.imessageAutomationSkippedPath)?.boolValue ?? Self.imessageAutomationSkippedDefault
    }

    static func imessageDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        [imessageEnabledPath, imessageAutomationSkippedPath].compactMap { path in
            guard let value = root.value(at: path), value.boolValue == nil else { return nil }
            return SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false")
        }
    }

    static var imessageDescriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.section.accounts", "Accounts")
        return [
            SettingDescriptor(
                imessageEnabledPath, section: .accounts, group: group,
                title: SettingsText.keyed("settings.imessage.enabled", "Connect iMessage"),
                help: SettingsText.keyed("settings.imessage.enabled.help",
                                        "Allow reading Messages conversations on this Mac after connecting in Session Info. Sending still needs your click."),
                kind: .toggle, default: .bool(imessageEnabledDefault),
                keywords: ["imessage", "messages", "connector", "privacy"]
            ).hiddenFromSettingsPage("connect and disconnect from Session Info's iMessage connector"),
            SettingDescriptor(
                imessageAutomationSkippedPath, section: .accounts, group: group,
                title: SettingsText.keyed("settings.imessage.automationSkipped", "Skip Messages Automation"),
                help: SettingsText.keyed("settings.imessage.automationSkipped.help",
                                        "Remember skipping the Messages Automation step. This does not grant access or authorize sending."),
                kind: .toggle, default: .bool(imessageAutomationSkippedDefault),
                keywords: ["imessage", "messages", "automation", "connector"]
            ).hiddenFromSettingsPage("permission walkthrough state, set only by the iMessage connector"),
        ]
    }
}
