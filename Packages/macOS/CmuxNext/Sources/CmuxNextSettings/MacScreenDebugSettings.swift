/// `macScreen.debug.*` in cmux.json, the Development section's Mac Screen
/// switches. Only DEV builds read them (the section shows only there);
/// every other build ignores the keys.
/// - `relayOnly` (off by default): Mac Screen streams use the TURN relay
///   only, to check the relay path. It applies to sessions that connect
///   after the change.
public nonisolated struct MacScreenDebugSettings: Sendable, Equatable {
    public static let relayOnlyPath = ["macScreen", "debug", "relayOnly"]
    public var relayOnly = false

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["macScreen", "debug"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("relayOnly") { settings.relayOnly = value }
        diagnostics = reader.diagnostics
        return settings
    }
}

/// The Development section's Mac Screen rows.
nonisolated enum MacScreenDebugSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.macScreen", "Mac Screen")
        return [
            SettingDescriptor(
                MacScreenDebugSettings.relayOnlyPath, section: .development, group: group,
                title: SettingsText.keyed("settings.macScreen.debug.relayOnly", "Relay Only"),
                help: SettingsText.keyed("settings.macScreen.debug.relayOnly.help",
                                         "Mac Screen tabs connect through the TURN relay only, never directly, to check the relay path. Tabs that are connected reconnect."),
                summary: SettingsText.keyed("settings.macScreen.debug.relayOnly.summary", "Mac Screen streams use the relay only"),
                kind: .toggle, default: .bool(MacScreenDebugSettings().relayOnly),
                keywords: ["mac screen", "relay", "turn", "webrtc", "ice", "development", "debug"]
            ),
        ]
    }
}
