import CmuxTerminalCore

/// Coalesced request waiting to replace Ghostty's runtime configuration.
struct TerminalPendingConfigurationReload {
    var soft: Bool
    var source: String
    var reloadSettingsFromFile: Bool
    var preferredColorScheme:
        GhosttyConfig.ColorSchemePreference?
    var completions: [GhosttyApp.ConfigurationReloadCompletion]

    mutating func merge(
        _ newer: TerminalPendingConfigurationReload
    ) {
        soft = soft && newer.soft
        source = newer.source
        reloadSettingsFromFile =
            reloadSettingsFromFile
            || newer.reloadSettingsFromFile
        preferredColorScheme = newer.preferredColorScheme
        completions.append(
            contentsOf: newer.completions
        )
    }
}
