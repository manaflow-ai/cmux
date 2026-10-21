// The paths and defaults are generated from schemas/settings/source/now-playing.json
// (Schema/SettingsSchema+NowPlaying.generated.swift); this file only parses.

/// The Now Playing player in cmux.json: `sidebar.nowPlaying.enabled` shows the sidebar card (off by
/// default; a tab playing sound shows its speaker in the tab strip), and `tabs.newTabNowPlaying`
/// shows the New Tab page's player (on by default; its menu's Hide Now Playing turns it off).
public nonisolated struct NowPlayingSettings: Sendable, Equatable {
    public var enabled = NowPlayingSettings.enabledDefault
    /// `tabs.newTabNowPlaying`: the New Tab page's player (its menu's Hide Now Playing turns it off).
    public var newTab = NowPlayingSettings.newTabDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        if var reader = ConfigFieldReader(root, at: ["sidebar", "nowPlaying"], diagnostics: &diagnostics) {
            if let value = reader.bool("enabled") { settings.enabled = value }
            diagnostics += reader.diagnostics
        }
        // Read at its own path, as `tabs.newTabTemplate` is: `tabs` holds other settings' keys.
        if let value = root.value(at: newTabPath) {
            if let bool = value.boolValue { settings.newTab = bool } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: newTabPath.joined(separator: "."), message: "expected true or false"))
            }
        }
        return settings
    }
}
