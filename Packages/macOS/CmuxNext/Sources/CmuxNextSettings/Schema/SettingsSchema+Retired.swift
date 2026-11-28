extension SettingsSchema {
    // `retiredKeys` is generated from schemas/settings/retired-keys.json
    // (SettingsSchema+RetiredKeys.generated.swift, cx-d5b5d); the daemon
    // reads the same file.

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
