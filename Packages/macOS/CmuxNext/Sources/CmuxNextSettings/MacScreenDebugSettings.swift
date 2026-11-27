/// `macScreen.debug.*` in cmux.json, the Development section's Mac Screen
/// switches. Only DEV builds read them (the section shows only there);
/// every other build ignores the keys.
/// - `relayOnly` (off by default): Mac Screen streams use the TURN relay
///   only, to check the relay path. It applies to sessions that connect
///   after the change.
public nonisolated struct MacScreenDebugSettings: Sendable, Equatable {
    public var relayOnly = MacScreenDebugSettings.relayOnlyDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["macScreen", "debug"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("relayOnly") { settings.relayOnly = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
