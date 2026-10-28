import CmuxTerminalCore

/// Coalesced request waiting to replace Ghostty's runtime configuration.
///
/// `commitCompletions` acknowledge the validated app-configuration commit;
/// `completions` finish after the bounded terminal-surface propagation phase.
struct TerminalPendingConfigurationReload {
    var soft: Bool
    var source: String
    var reloadSettingsFromFile: Bool
    /// An explicit user reload re-applies cmux.json values for
    /// file-authoritative keys even when a Settings change diverged them.
    var appliesSettingsFileAuthority: Bool
    var preferredColorScheme:
        GhosttyConfig.ColorSchemePreference?
    var completions: [GhosttyApp.ConfigurationReloadCompletion]
    var commitCompletions: [GhosttyApp.ConfigurationReloadCommitCompletion]

    init(
        soft: Bool,
        source: String,
        reloadSettingsFromFile: Bool,
        appliesSettingsFileAuthority: Bool = false,
        preferredColorScheme:
            GhosttyConfig.ColorSchemePreference?,
        completions: [GhosttyApp.ConfigurationReloadCompletion],
        commitCompletions:
            [GhosttyApp.ConfigurationReloadCommitCompletion] = []
    ) {
        self.soft = soft
        self.source = source
        self.reloadSettingsFromFile = reloadSettingsFromFile
        self.appliesSettingsFileAuthority = appliesSettingsFileAuthority
        self.preferredColorScheme = preferredColorScheme
        self.completions = completions
        self.commitCompletions = commitCompletions
    }

    /// Reload sources a user triggers to apply their config files: `cmux
    /// reload-config`, Reload Configuration (menu, shortcut, Ghostty binding)
    /// and the config window. Settings-driven reloads are not listed, so they
    /// keep an in-session Settings change.
    static let settingsFileAuthoritySources: Set<String> = [
        "socket.reload_config",
        "menu.reload_configuration",
        "shortcut.reloadConfiguration",
        "action.reload_config.app",
        "settings.configWindow.reload",
        "settings.configWindow.save",
    ]

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
        appliesSettingsFileAuthority =
            appliesSettingsFileAuthority
            || newer.appliesSettingsFileAuthority
        preferredColorScheme = newer.preferredColorScheme
        completions.append(
            contentsOf: newer.completions
        )
        commitCompletions.append(
            contentsOf: newer.commitCompletions
        )
    }
}
