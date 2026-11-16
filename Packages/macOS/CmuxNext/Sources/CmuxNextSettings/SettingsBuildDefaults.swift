/// Defaults that depend on the running build rather than the schema. They fill keys that no layer
/// sets (the file, MDM, the team policy), in the effective root only: cmux-next.json is shared by
/// NIGHTLY, cmux NEXT, RC and stable, so a NIGHTLY default written there would become stable's value too
/// (a DEV build has a file of its own, `BuildStatePaths`, and starts it empty).
/// Settings shows them as the value in effect, and Reset returns to them.
public nonisolated struct SettingsBuildDefaults: Sendable, Equatable {
    public var values: [[String]: JSONValue]

    public static let none = SettingsBuildDefaults(values: [:])

    public init(values: [[String]: JSONValue]) {
        self.values = values
    }

    /// `updates.downloadAutomatically` follows the channel (`UpdateTrack.downloadsAutomaticallyByDefault`):
    /// on for cmux NEXT's nightly ring (Leo 2026-11-10: "the nightly automatically downloads and
    /// installs/unpacks and you simply click and it restarts"), filled here; off (the schema's
    /// default, `.none`) on every other channel.
    ///
    /// `mobile.allowIPhoneConnections` is on in a DEV build (`BuildStatePaths.isolatesSharedState`): DEV builds
    /// pair with the person's iPhone by default, so a fresh one is reachable from the phone without a trip to
    /// Settings. Its own file starts empty, so this is the value in effect until someone sets the key there;
    /// NIGHTLY and stable keep the schema's off.
    public static func channel(downloadsAutomatically: Bool, devBuild: Bool = false) -> SettingsBuildDefaults {
        var values: [[String]: JSONValue] = [:]
        if downloadsAutomatically { values[UpdatesSettings.downloadAutomaticallyPath] = .bool(true) }
        if devBuild { values[MobileSettings.allowIPhoneConnectionsPath] = .bool(true) }
        return SettingsBuildDefaults(values: values)
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

    /// Whether `value` is what `descriptor` has with its key unset: this build's default, and no layer
    /// below the file fills the key. The file then leaves the key out, so it follows a later change of
    /// the default (Leo 2026-11-08: "if I'm on the default selection and the default selection changes
    /// its properties, that's something that should happen").
    func isUnsetValue(_ value: JSONValue, of descriptor: SettingDescriptor) -> Bool {
        value == defaultValue(of: descriptor) && !layerBelowFileSets(descriptor.id)
    }

    /// Whether the person's file sets `descriptor` to something other than this build's default,
    /// so Settings offers Reset (an explicit off in NIGHTLY, whose default is on, counts).
    public func isCustomized(_ descriptor: SettingDescriptor) -> Bool {
        guard let stored = descriptor.storedValue(in: fileRoot) else { return false }
        return stored != defaultValue(of: descriptor)
    }
}
