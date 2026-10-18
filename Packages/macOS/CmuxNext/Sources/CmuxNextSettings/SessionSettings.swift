// The paths, defaults and the choice enum (SessionKeepAwakeSetting) are generated from
// schemas/settings/source/sessions.json (Schema/SettingsSchema+Sessions*.generated.swift);
// this file only parses.

/// `sessions.*` in cmux.json: what this Mac does while agent sessions run. Idle sleep
/// stays off while an agent works on adapter power unless the user picks otherwise.
public nonisolated struct SessionSettings: Sendable, Equatable {
    public var keepAwake = SessionSettings.keepAwakeDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["sessions"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.choice("keepAwake", SessionKeepAwakeSetting.self) { settings.keepAwake = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
