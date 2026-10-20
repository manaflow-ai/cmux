// The path and default are generated from schemas/settings/source/now-playing.json
// (Schema/SettingsSchema+NowPlaying.generated.swift); this file only parses.

/// `sidebar.nowPlaying.*` in cmux.json: the Now Playing player shows in the
/// sidebar and on the new chat page only when the user turns it on (off by
/// default; a tab playing sound shows its speaker in the tab strip).
public nonisolated struct NowPlayingSettings: Sendable, Equatable {
    public var enabled = NowPlayingSettings.enabledDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["sidebar", "nowPlaying"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("enabled") { settings.enabled = value }
        diagnostics += reader.diagnostics
        return settings
    }
}
