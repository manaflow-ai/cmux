extension SettingsSchema {
    /// cmux.json keys cmux used to read and no longer does, with why. The
    /// loader drops them without a diagnostic (an old file keeps loading
    /// cleanly), the schema export and Settings never list them, and a
    /// write through `settings.set` or the palette is refused as removed
    /// (`SettingRetired`), not as unknown.
    public static let retiredKeys: [String: String] = [
        // One background everywhere (plans/cmux-next/windows.md, 2026-10-03).
        "appearance.tabBarBackground": "every surface draws the one window background",
        // The update card is gone (Lawrence 2026-10-05): nothing left to quiet.
        "updates.quietHours": "a staged update shows only the small control on Settings",
    ]

    /// Whether `path` is a retired key.
    public static func isRetired(_ path: [String]) -> Bool {
        retiredKeys[path.joined(separator: ".")] != nil
    }
}

/// A write to a key in `SettingsSchema.retiredKeys`.
public nonisolated struct SettingRetired: Error, Sendable, CustomStringConvertible {
    public let key: String
    public init(key: String) { self.key = key }
    public var description: String {
        "\(key) was removed: \(SettingsSchema.retiredKeys[key] ?? "no longer read")"
    }
}
