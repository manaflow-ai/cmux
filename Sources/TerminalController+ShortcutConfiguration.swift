import AppKit

#if DEBUG
extension TerminalController {
    func setShortcut(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: set_shortcut <name> <combo|clear>"
        }

        let name = parts[0].lowercased()
        let combo = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        let action: KeyboardShortcutSettings.Action?
        switch name {
        case "focus_left", "focusleft":
            action = .focusLeft
        case "focus_right", "focusright":
            action = .focusRight
        case "focus_up", "focusup":
            action = .focusUp
        case "focus_down", "focusdown":
            action = .focusDown
        case "split_right", "splitright":
            action = .splitRight
        case "split_down", "splitdown":
            action = .splitDown
        case "resize_pane_left", "resizepaneleft", "resize-pane-left":
            action = .resizePaneLeft
        case "resize_pane_right", "resizepaneright", "resize-pane-right":
            action = .resizePaneRight
        case "resize_pane_up", "resizepaneup", "resize-pane-up":
            action = .resizePaneUp
        case "resize_pane_down", "resizepanedown", "resize-pane-down":
            action = .resizePaneDown
        case "workspace_digits", "workspace_number", "select_workspace_by_number":
            action = .selectWorkspaceByNumber
        case "surface_digits", "surface_number", "select_surface_by_number":
            action = .selectSurfaceByNumber
        default:
            action = nil
        }

        guard let action else {
            return "ERROR: Unknown shortcut name. Supported: focus_left, focus_right, focus_up, focus_down, split_right, split_down, resize_pane_left, resize_pane_right, resize_pane_up, resize_pane_down, workspace_digits, surface_digits"
        }

        if combo.lowercased() == "clear" || combo.lowercased() == "unbound" || combo.lowercased() == "none" {
            KeyboardShortcutSettings.clearShortcut(for: action)
            return "OK"
        }

        if combo.lowercased() == "default" || combo.lowercased() == "reset" {
            KeyboardShortcutSettings.resetShortcut(for: action)
            return "OK"
        }

        guard let parsed = SyntheticKeyEventFactory.parseShortcutCombo(combo) else {
            return "ERROR: Invalid combo. Example: cmd+ctrl+h"
        }

        let shortcut = StoredShortcut(
            key: parsed.storedKey,
            command: parsed.modifierFlags.contains(.command),
            shift: parsed.modifierFlags.contains(.shift),
            option: parsed.modifierFlags.contains(.option),
            control: parsed.modifierFlags.contains(.control)
        )
        if action.usesNumberedDigitMatching,
           action.normalizedRecordedShortcut(shortcut) == nil {
            return "ERROR: Numbered shortcuts must use a digit key (1-9). Example: ctrl+1"
        }

        let storedShortcut = action.normalizedRecordedShortcut(shortcut) ?? shortcut
        KeyboardShortcutSettings.setShortcut(storedShortcut, for: action)
        return "OK"
    }

}
#endif
