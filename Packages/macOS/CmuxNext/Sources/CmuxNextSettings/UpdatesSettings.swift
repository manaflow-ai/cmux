/// What automatic downloads do on a metered link (`updates.meteredNetwork`).
public nonisolated enum UpdatesMeteredSetting: String, Sendable, Hashable, CaseIterable {
    case deferLowData = "defer-low-data"
    case deferExpensive = "defer-expensive"
    case download
}

/// How a ready update makes itself known (`updates.notify`): the control
/// on the Settings item, or nothing (installs on quit). The old `card`
/// value (the update card, removed 2026-10-05) loads as `badge`.
public nonisolated enum UpdatesNotifySetting: String, Sendable, Hashable, CaseIterable {
    case badge, silent

    /// Values older files may hold, read as their replacement without a
    /// diagnostic.
    static let legacyValues: [String: Self] = ["card": .badge]
}

/// `updates.*` in cmux.json (R114): automatic checks, downloads and
/// install on quit are on by default; every step can be turned off.
public nonisolated struct UpdatesSettings: Sendable, Equatable {
    public static let checkIntervalRange: ClosedRange<Double> = 900...604_800
    public var checkAutomatically = true
    /// Seconds between automatic checks.
    public var checkIntervalSeconds: Double = 3600
    public var downloadAutomatically = true
    public var installOnQuit = true
    public var notify: UpdatesNotifySetting = .badge
    /// Previous builds kept for rollback (`cmux update rollback`).
    public var keepPreviousVersions = 1
    public static let keepPreviousVersionsRange: ClosedRange<Double> = 0...5
    public var meteredNetwork: UpdatesMeteredSetting = .deferLowData
    public static let meteredNetworkPath = ["updates", "meteredNetwork"]

    public init() {}

    public static let checkAutomaticallyPath = ["updates", "checkAutomatically"]
    public static let checkIntervalPath = ["updates", "checkIntervalSeconds"]
    public static let downloadAutomaticallyPath = ["updates", "downloadAutomatically"]
    public static let installOnQuitPath = ["updates", "installOnQuit"]
    public static let notifyPath = ["updates", "notify"]
    public static let keepPreviousVersionsPath = ["updates", "keepPreviousVersions"]

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["updates"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("checkAutomatically") { settings.checkAutomatically = value }
        if let value = reader.number("checkIntervalSeconds", range: checkIntervalRange) { settings.checkIntervalSeconds = value }
        if let value = reader.bool("downloadAutomatically") { settings.downloadAutomatically = value }
        if let value = reader.bool("installOnQuit") { settings.installOnQuit = value }
        if let legacy = root.value(at: notifyPath)?.stringValue.flatMap({ UpdatesNotifySetting.legacyValues[$0] }) {
            settings.notify = legacy
        } else if let value = reader.choice("notify", UpdatesNotifySetting.self) {
            settings.notify = value
        }
        if let value = reader.choice("meteredNetwork", UpdatesMeteredSetting.self) { settings.meteredNetwork = value }
        if let value = reader.number("keepPreviousVersions", range: keepPreviousVersionsRange) { settings.keepPreviousVersions = Int(value) }
        diagnostics = reader.diagnostics
        return settings
    }
}
