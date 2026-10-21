// The paths, defaults, ranges and the choice enums (UpdatesMeteredSetting, UpdatesNotifySetting)
// are generated from schemas/settings/source/updates.json (Schema/SettingsSchema+Updates*.generated.swift,
// cx-d5b5d); this file only parses.

/// `updates.*` in cmux.json (R114): automatic checks, downloads and
/// install on quit are on by default; every step can be turned off.
public nonisolated struct UpdatesSettings: Sendable, Equatable {
    public var checkAutomatically = UpdatesSettings.checkAutomaticallyDefault
    /// Seconds between automatic checks.
    public var checkIntervalSeconds = UpdatesSettings.checkIntervalDefault
    public var downloadAutomatically = UpdatesSettings.downloadAutomaticallyDefault
    public var installOnQuit = UpdatesSettings.installOnQuitDefault
    public var notify = UpdatesSettings.notifyDefault
    /// Previous builds kept for rollback (`cmux update rollback`).
    public var keepPreviousVersions = Int(UpdatesSettings.keepPreviousVersionsDefault)
    public var meteredNetwork = UpdatesSettings.meteredNetworkDefault
    /// The bottom-left "cmux Updated!" card after an update
    /// (WHATS-NEW-AFTER-UPDATE W1); managed config can force it off.
    public var showWhatsNew = UpdatesSettings.showWhatsNewDefault

    public init() {}

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
        if let value = reader.bool("showWhatsNew") { settings.showWhatsNew = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
