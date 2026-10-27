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

extension SettingsController {
    /// `descriptor`'s default in this build: its build default (``SettingsBuildDefaults``), else the schema's.
    public func defaultValue(of descriptor: SettingDescriptor) -> JSONValue? {
        buildDefaults.values[descriptor.path] ?? descriptor.defaultValue
    }

    /// Whether the person's file sets `descriptor` to something other than this build's default,
    /// so Settings offers Reset (an explicit off in NIGHTLY, whose default is on, counts).
    public func isCustomized(_ descriptor: SettingDescriptor) -> Bool {
        guard let stored = descriptor.storedValue(in: fileRoot) else { return false }
        return stored != defaultValue(of: descriptor)
    }
}
