/// `app.showMenuBarIcon`: the cmux item in the macOS menu bar (user 2026-10-27, after Raycast's):
/// open cmux, the account, the agents that work or wait, help, community links, updates, logs and
/// Quit. On when unset or invalid. Off removes the item while a cmux window is open; with no
/// window open and `app.hideDockIconWithoutWindows` on, background mode's own item still shows,
/// so there is always a way back to cmux.
nonisolated extension CmuxConfigSnapshot {
    public static let showMenuBarIconPath = ["app", "showMenuBarIcon"]
    /// On when unset or invalid.
    public static let showMenuBarIconFallback = true

    /// `app.showMenuBarIcon`.
    public var showMenuBarIcon: Bool {
        root.value(at: Self.showMenuBarIconPath)?.boolValue ?? Self.showMenuBarIconFallback
    }

    /// A diagnostic when `app.showMenuBarIcon` is set to something other than a bool.
    static func showMenuBarIconDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        guard let value = root.value(at: showMenuBarIconPath), value.boolValue == nil else { return [] }
        return [SettingsDiagnostic(kind: .invalidValue, path: showMenuBarIconPath.joined(separator: "."), message: "expected true or false")]
    }
}
