import Foundation

extension SettingsSearchIndex {
    static let declarativeTerminalSettingEntries: [SettingsSearchEntry] = [
        setting(
            .terminal,
            "new-surface-working-directory-policy",
            String(
                localized: "settings.terminal.newSurfaceWorkingDirectory.policy",
                defaultValue: "New Surface Working Directory"
            ),
            String(
                localized: "settings.search.alias.setting.terminal.new-surface-working-directory-policy",
                defaultValue: "terminal.newSurfaceWorkingDirectory policy working directory cwd current pane workspace root fixed path inherit split tab pane app.workspaceInheritWorkingDirectory legacy"
            )
        ),
        setting(
            .terminal,
            "new-surface-working-directory-path",
            String(
                localized: "settings.terminal.newSurfaceWorkingDirectory.path",
                defaultValue: "Fixed Directory"
            ),
            String(
                localized: "settings.search.alias.setting.terminal.new-surface-working-directory-path",
                defaultValue: "terminal.newSurfaceWorkingDirectory path fixed directory cwd folder tilde workspace root"
            )
        ),
        setting(
            .terminal,
            "shell-startup-mode",
            String(
                localized: "settings.terminal.shellStartup.mode",
                defaultValue: "Shell Startup Mode"
            ),
            String(
                localized: "settings.search.alias.setting.terminal.shell-startup-mode",
                defaultValue: "terminal.shellStartup mode shell login non-login interactive startup"
            )
        ),
        setting(
            .terminal,
            "shell-startup-command",
            String(
                localized: "settings.terminal.shellStartup.command",
                defaultValue: "Startup Command"
            ),
            String(
                localized: "settings.search.alias.setting.terminal.shell-startup-command",
                defaultValue: "terminal.shellStartup command shell startup input command activate zsh mise"
            )
        ),
    ]

    static let declarativeTerminalSettingsPathAnchorIDs: [String: String] = [
        "terminal.newSurfaceWorkingDirectory.policy": settingID(
            for: .terminal,
            idSuffix: "new-surface-working-directory-policy"
        ),
        "terminal.newSurfaceWorkingDirectory.path": settingID(
            for: .terminal,
            idSuffix: "new-surface-working-directory-path"
        ),
        "terminal.shellStartup.mode": settingID(
            for: .terminal,
            idSuffix: "shell-startup-mode"
        ),
        "terminal.shellStartup.command": settingID(
            for: .terminal,
            idSuffix: "shell-startup-command"
        ),
    ]
}
