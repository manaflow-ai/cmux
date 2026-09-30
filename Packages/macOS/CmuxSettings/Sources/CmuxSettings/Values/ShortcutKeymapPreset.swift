import Foundation

/// A base keymap for people coming from another terminal, like Zed's base
/// keymap picker.
///
/// A preset is a list of `shortcuts.bindings` overrides. Every override
/// differs from the cmux default, so the ``cmux`` preset has none and choosing
/// it removes the overrides another preset wrote. Presets map only actions
/// cmux has; a terminal's shortcut that already matches cmux (for example
/// iTerm2's Cmd-D, Cmd-Shift-D, Cmd-Opt-arrows, Cmd-Shift-Return and Cmd-T)
/// needs no override.
public enum ShortcutKeymapPreset: String, CaseIterable, Sendable {
    /// cmux's built-in shortcuts.
    case cmux
    /// iTerm2's defaults: Cmd-1…9 selects tabs, Cmd-Opt-1…9 selects windows,
    /// Cmd-Shift-C enters copy mode, and Cmd-Ctrl-arrows move pane dividers.
    case iTerm2 = "iterm2"
    /// Terminal.app's defaults: Cmd-Opt-W closes other tabs and Cmd-Shift-I
    /// edits the tab title.
    case terminal
    /// tmux's default `ctrl+b` prefix, with tmux windows mapped to cmux
    /// workspaces and tmux panes to cmux panes.
    case tmux

    /// The `shortcuts.bindings` values this preset writes, keyed by action.
    ///
    /// Values use the hand-editable `cmux.json` forms so the file stays
    /// readable after a preset is applied.
    public var overrides: [ShortcutAction: ShortcutKeymapBinding] {
        switch self {
        case .cmux:
            return [:]
        case .iTerm2:
            return [
                .selectSurfaceByNumber: .stroke("cmd+1"),
                .selectWorkspaceByNumber: .stroke("cmd+opt+1"),
                .toggleTerminalCopyMode: .stroke("cmd+shift+c"),
                .resizePaneLeft: .stroke("cmd+ctrl+left"),
                .resizePaneRight: .stroke("cmd+ctrl+right"),
                .resizePaneUp: .stroke("cmd+ctrl+up"),
                .resizePaneDown: .stroke("cmd+ctrl+down"),
            ]
        case .terminal:
            return [
                .closeOtherTabsInPane: .stroke("cmd+opt+w"),
                .renameTab: .stroke("cmd+shift+i"),
            ]
        case .tmux:
            let prefix = "ctrl+b"
            return [
                .newTab: .chord(prefix, "c"),
                .closeTab: .chord(prefix, "x"),
                .closeWorkspace: .chord(prefix, "shift+7"),
                .nextSidebarTab: .chord(prefix, "n"),
                .prevSidebarTab: .chord(prefix, "p"),
                .selectWorkspaceByNumber: .chord(prefix, "1"),
                .renameWorkspace: .chord(prefix, ","),
                .goToWorkspace: .chord(prefix, "w"),
                .splitRight: .chord(prefix, "shift+5"),
                .splitDown: .chord(prefix, "shift+'"),
                .focusLeft: .chord(prefix, "left"),
                .focusRight: .chord(prefix, "right"),
                .focusUp: .chord(prefix, "up"),
                .focusDown: .chord(prefix, "down"),
                .focusNextPane: .chord(prefix, "o"),
                .toggleSplitZoom: .chord(prefix, "z"),
                .toggleTerminalCopyMode: .chord(prefix, "["),
            ]
        }
    }
}
