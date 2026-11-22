/// `computerUse.*` in cmux.json. `enabled` (off by default) lets cmux start
/// the Developer ID signed cmux Computer Use helper, so agents can see and
/// use other apps. Off, no helper starts and macOS asks for nothing.
public nonisolated struct ComputerUseSettings: Sendable, Equatable {
    public static let enabledPath = ["computerUse", "enabled"]
    public var enabled = false

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["computerUse"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        diagnostics = reader.diagnostics
        return settings
    }
}

/// The Computer Use settings rows.
nonisolated enum ComputerUseSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.computerUse", "Computer Use")
        return [
            SettingDescriptor(
                ComputerUseSettings.enabledPath, section: .general, group: group,
                title: SettingsText.keyed("settings.computerUse.enabled", "Computer Use"),
                help: SettingsText.keyed("settings.computerUse.enabled.help",
                                         "Lets agents see and use your apps through the signed cmux Computer Use helper. macOS asks for Accessibility and Screen Recording when you first allow them."),
                kind: .toggle, default: .bool(ComputerUseSettings().enabled),
                keywords: ["computer use", "agents", "automation", "screen recording", "accessibility", "helper"]
            ),
        ]
    }
}
