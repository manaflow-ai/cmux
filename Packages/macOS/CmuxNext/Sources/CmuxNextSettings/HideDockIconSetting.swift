/// `app.hideDockIconWithoutWindows`: with no cmux window open, cmux keeps
/// running as a menu bar app, with no Dock icon and no Cmd-Tab entry, and its
/// menu bar item brings a window back (Leo 2026-10-13, cx-ghagp). On when
/// unset or invalid; false keeps the Dock icon with no window open, as before.
nonisolated extension CmuxConfigSnapshot {
    public static let hideDockIconWithoutWindowsPath = ["app", "hideDockIconWithoutWindows"]
    /// On when unset or invalid.
    public static let hideDockIconWithoutWindowsFallback = true

    /// `app.hideDockIconWithoutWindows`.
    public var hideDockIconWithoutWindows: Bool {
        root.value(at: Self.hideDockIconWithoutWindowsPath)?.boolValue ?? Self.hideDockIconWithoutWindowsFallback
    }

    /// A diagnostic when `app.hideDockIconWithoutWindows` is set to something other than a bool.
    static func hideDockIconWithoutWindowsDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        guard let value = root.value(at: hideDockIconWithoutWindowsPath), value.boolValue == nil else { return [] }
        return [SettingsDiagnostic(kind: .invalidValue, path: hideDockIconWithoutWindowsPath.joined(separator: "."),
                                   message: "expected true or false")]
    }
}
