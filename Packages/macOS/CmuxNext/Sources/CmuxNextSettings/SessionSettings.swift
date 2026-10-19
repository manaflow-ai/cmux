// The paths, defaults and the choice enums (SessionKeepAwakeSetting, PhoneKeepAwakeSetting) are generated from
// schemas/settings/source/sessions.json (Schema/SettingsSchema+Sessions*.generated.swift);
// this file only parses.

/// `sessions.*`, `phone.*` and `remoteHosting.*` in cmux.json: what this Mac does while agent sessions run,
/// and for phones signed in to the same cmux account. Idle sleep stays off while an agent
/// works on adapter power unless the user picks otherwise; phone access is off until turned on.
public nonisolated struct SessionSettings: Sendable, Equatable {
    public var keepAwake = SessionSettings.keepAwakeDefault
    /// `phone.allowConnections`: the phone listener runs.
    public var allowsPhone = SessionSettings.allowConnectionsDefault
    /// `phone.startSessions`: phones may create workspaces and terminals.
    public var phoneStartsSessions = SessionSettings.startSessionsDefault
    /// `phone.keepAwake`: idle sleep stays off while phones can reach this Mac.
    public var phoneKeepAwake = SessionSettings.phoneKeepAwakeDefault
    /// `remoteHosting.enabled`: this Mac serves the app's session to the owner's other
    /// devices; nil while unset (the app then leaves hosting as the CLI set it).
    public var remoteHosting: Bool?

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        if var reader = ConfigFieldReader(root, at: ["sessions"], diagnostics: &diagnostics) {
            if let value = reader.choice("keepAwake", SessionKeepAwakeSetting.self) { settings.keepAwake = value }
            diagnostics += reader.diagnostics
        }
        if var reader = ConfigFieldReader(root, at: ["phone"], diagnostics: &diagnostics) {
            if let value = reader.bool("allowConnections") { settings.allowsPhone = value }
            if let value = reader.bool("startSessions") { settings.phoneStartsSessions = value }
            if let value = reader.choice("keepAwake", PhoneKeepAwakeSetting.self) { settings.phoneKeepAwake = value }
            diagnostics += reader.diagnostics
        }
        if var reader = ConfigFieldReader(root, at: ["remoteHosting"], diagnostics: &diagnostics) {
            if let value = reader.bool("enabled") { settings.remoteHosting = value }
            diagnostics += reader.diagnostics
        }
        return settings
    }
}
