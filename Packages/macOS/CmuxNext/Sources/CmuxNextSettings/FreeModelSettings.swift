/// `freeModel.*` in cmux.json (cx-ds09i): `enabled` (on by default) lets this
/// Mac use the free cmux AI model without a sign-in. The local model relay
/// then proves the Mac to the cmux API (App Attest) at the first signed-out
/// agent request, never at launch. An MDM profile or a team policy can force
/// it off; a Mac that cannot prove itself shows sign-in instead.
public nonisolated struct FreeModelSettings: Sendable, Equatable {
    public static let enabledPath = ["freeModel", "enabled"]
    public var enabled = true

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["freeModel"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        diagnostics = reader.diagnostics
        return settings
    }
}

/// The free model settings row.
nonisolated enum FreeModelSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.freeModel", "AI Models")
        return [
            SettingDescriptor(
                FreeModelSettings.enabledPath, section: .general, group: group,
                title: SettingsText.keyed("settings.freeModel.enabled", "Free AI Model Without Sign-In"),
                help: SettingsText.keyed("settings.freeModel.enabled.help",
                                         "Lets agents use the free cmux AI model while you are signed out. The first time an agent uses it, cmux proves to the Cloud service that this is a real Mac. Sign in for more models and higher limits."),
                summary: SettingsText.keyed("settings.freeModel.enabled.summary", "Free AI model while signed out"),
                kind: .toggle, default: .bool(FreeModelSettings().enabled),
                keywords: ["ai", "model", "free", "sign in", "agents", "models"]
            ),
        ]
    }
}
