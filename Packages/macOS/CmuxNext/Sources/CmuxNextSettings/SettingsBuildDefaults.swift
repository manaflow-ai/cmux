/// Defaults that depend on the running build rather than the schema. They fill keys that no layer
/// sets (the file, MDM, the team policy), in the effective root only: cmux-next.json is shared by
/// every channel, so a NIGHTLY or DEV default written there would become stable's value too.
/// Settings shows them as the value in effect, and Reset returns to them.
public nonisolated struct SettingsBuildDefaults: Sendable, Equatable {
    public var values: [[String]: JSONValue]

    public static let none = SettingsBuildDefaults(values: [:])

    public init(values: [[String]: JSONValue]) {
        self.values = values
    }

    /// `updates.downloadAutomatically` follows the channel: on in NIGHTLY and DEV, off (the schema's
    /// default) on stable.
    public static func channel(downloadsAutomatically: Bool) -> SettingsBuildDefaults {
        downloadsAutomatically ? SettingsBuildDefaults(values: [UpdatesSettings.downloadAutomaticallyPath: .bool(true)]) : .none
    }

    /// `root` with every build default whose key it leaves unset.
    func filling(_ root: JSONValue) -> JSONValue {
        values.reduce(root) { root, entry in root.value(at: entry.key) == nil ? root.setting(entry.value, at: entry.key) : root }
    }
}
