import CmuxTerminalCore

/// Coalesced request waiting to replace Ghostty's runtime configuration.
///
/// `commitCompletions` acknowledge the validated app-configuration commit;
/// `completions` finish after the bounded terminal-surface propagation phase.
struct TerminalPendingConfigurationReload {
    var soft: Bool
    var source: String
    var reloadSettingsFromFile: Bool
    var preferredColorScheme:
        GhosttyConfig.ColorSchemePreference?
    var completions: [GhosttyApp.ConfigurationReloadCompletion]
    var commitCompletions: [GhosttyApp.ConfigurationReloadCommitCompletion]

    init(
        soft: Bool,
        source: String,
        reloadSettingsFromFile: Bool,
        preferredColorScheme:
            GhosttyConfig.ColorSchemePreference?,
        completions: [GhosttyApp.ConfigurationReloadCompletion],
        commitCompletions:
            [GhosttyApp.ConfigurationReloadCommitCompletion] = []
    ) {
        self.soft = soft
        self.source = source
        self.reloadSettingsFromFile = reloadSettingsFromFile
        self.preferredColorScheme = preferredColorScheme
        self.completions = completions
        self.commitCompletions = commitCompletions
    }

    var totalCompletionCount: Int {
        completions.count + commitCompletions.count
    }

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
        commitCompletions.append(
            contentsOf: newer.commitCompletions
        )
    }
}
