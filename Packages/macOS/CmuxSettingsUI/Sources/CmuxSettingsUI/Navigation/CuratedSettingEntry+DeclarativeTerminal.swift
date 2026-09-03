import CmuxSettings
import Foundation

extension Array where Element == CuratedSettingEntry {
    /// Curated search entries for the declarative terminal configuration rows.
    static var declarativeTerminalEntries: [CuratedSettingEntry] {
        [
            .init(
                section: .terminal,
                id: "new-surface-working-directory-policy",
                title: String(localized: "settings.terminal.newSurfaceWorkingDirectory.policy", defaultValue: "New Surface Working Directory"),
                detailText: String(localized: "settings.terminal.newSurfaceWorkingDirectory.policy.subtitle", defaultValue: "Choose the default directory for new local panes, tabs, splits, and workspaces. Explicit and restored startup work keeps its own directory."),
                paths: [
                    "terminal.newSurfaceWorkingDirectory.policy",
                    "app.workspaceInheritWorkingDirectory",
                ],
                synonyms: String(
                    localized: "settings.search.alias.setting.terminal.new-surface-working-directory-policy",
                    defaultValue: "terminal.newSurfaceWorkingDirectory policy working directory cwd current pane workspace root fixed path inherit split tab pane app.workspaceInheritWorkingDirectory legacy"
                )
            ),
            .init(
                section: .terminal,
                id: "new-surface-working-directory-path",
                title: String(localized: "settings.terminal.newSurfaceWorkingDirectory.path", defaultValue: "Fixed Directory"),
                detailText: String(localized: "settings.terminal.newSurfaceWorkingDirectory.path.subtitle", defaultValue: "Used only with Fixed Path. Enter an absolute path or one beginning with ~; a missing or non-directory path falls back to the workspace root."),
                paths: ["terminal.newSurfaceWorkingDirectory.path"],
                synonyms: String(
                    localized: "settings.search.alias.setting.terminal.new-surface-working-directory-path",
                    defaultValue: "terminal.newSurfaceWorkingDirectory path fixed directory cwd folder tilde workspace root"
                )
            ),
            .init(
                section: .terminal,
                id: "shell-startup-mode",
                title: String(localized: "settings.terminal.shellStartup.mode", defaultValue: "Shell Startup Mode"),
                detailText: String(localized: "settings.terminal.shellStartup.mode.subtitle", defaultValue: "Select whether ordinary new local surfaces start an interactive login or non-login shell."),
                paths: ["terminal.shellStartup.mode"],
                synonyms: String(
                    localized: "settings.search.alias.setting.terminal.shell-startup-mode",
                    defaultValue: "terminal.shellStartup mode shell login non-login interactive startup"
                )
            ),
            .init(
                section: .terminal,
                id: "shell-startup-command",
                title: String(localized: "settings.terminal.shellStartup.command", defaultValue: "Startup Command"),
                detailText: String(localized: "settings.terminal.shellStartup.command.subtitle", defaultValue: "Optional command sent after an ordinary new local shell starts. Explicit commands, remote sessions, and restored surfaces are not changed."),
                paths: ["terminal.shellStartup.command"],
                synonyms: String(
                    localized: "settings.search.alias.setting.terminal.shell-startup-command",
                    defaultValue: "terminal.shellStartup command shell startup input command activate zsh mise"
                )
            ),
        ]
    }
}
