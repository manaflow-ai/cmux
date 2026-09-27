import CmuxSettings
import Foundation

extension ShortcutKeymapPreset {
    /// The name shown in the Base Keymap picker and the Command Palette.
    public var displayName: String {
        switch self {
        case .cmux:
            return String(localized: "shortcut.keymap.preset.cmux", defaultValue: "cmux (Default)")
        case .iTerm2:
            return String(localized: "shortcut.keymap.preset.iterm2", defaultValue: "iTerm2")
        case .terminal:
            return String(localized: "shortcut.keymap.preset.terminal", defaultValue: "Terminal.app")
        case .tmux:
            return String(localized: "shortcut.keymap.preset.tmux", defaultValue: "tmux-style (Ctrl-B Prefix)")
        }
    }
}

extension MacOSSystemShortcut {
    /// The System Settings name of the macOS shortcut.
    public var displayName: String {
        switch self {
        case .spotlight:
            return String(localized: "shortcut.macos.spotlight", defaultValue: "Show Spotlight search")
        case .finderSearch:
            return String(localized: "shortcut.macos.finderSearch", defaultValue: "Show Finder search window")
        case .previousInputSource:
            return String(localized: "shortcut.macos.previousInputSource", defaultValue: "Select the previous input source")
        case .nextInputSource:
            return String(localized: "shortcut.macos.nextInputSource", defaultValue: "Select the next input source")
        case .appSwitcher:
            return String(localized: "shortcut.macos.appSwitcher", defaultValue: "Switch apps")
        case .appSwitcherReverse:
            return String(localized: "shortcut.macos.appSwitcherReverse", defaultValue: "Switch apps backward")
        case .nextWindow:
            return String(localized: "shortcut.macos.nextWindow", defaultValue: "Move focus to the next window")
        case .previousWindow:
            return String(localized: "shortcut.macos.previousWindow", defaultValue: "Move focus to the previous window")
        case .missionControl:
            return String(localized: "shortcut.macos.missionControl", defaultValue: "Show Mission Control")
        case .applicationWindows:
            return String(localized: "shortcut.macos.applicationWindows", defaultValue: "Show application windows")
        case .spaceLeft:
            return String(localized: "shortcut.macos.spaceLeft", defaultValue: "Move left a space")
        case .spaceRight:
            return String(localized: "shortcut.macos.spaceRight", defaultValue: "Move right a space")
        case .screenshotScreen:
            return String(localized: "shortcut.macos.screenshotScreen", defaultValue: "Save picture of screen as a file")
        case .screenshotSelection:
            return String(localized: "shortcut.macos.screenshotSelection", defaultValue: "Save picture of selected area as a file")
        case .screenshotToolbar:
            return String(localized: "shortcut.macos.screenshotToolbar", defaultValue: "Screenshot and recording options")
        case .screenshotScreenToClipboard:
            return String(localized: "shortcut.macos.screenshotScreenToClipboard", defaultValue: "Copy picture of screen to the clipboard")
        case .screenshotSelectionToClipboard:
            return String(localized: "shortcut.macos.screenshotSelectionToClipboard", defaultValue: "Copy picture of selected area to the clipboard")
        case .toggleDockHiding:
            return String(localized: "shortcut.macos.toggleDockHiding", defaultValue: "Turn Dock hiding on or off")
        case .lockScreen:
            return String(localized: "shortcut.macos.lockScreen", defaultValue: "Lock Screen")
        case .logOut:
            return String(localized: "shortcut.macos.logOut", defaultValue: "Log Out")
        case .characterViewer:
            return String(localized: "shortcut.macos.characterViewer", defaultValue: "Show Emoji & Symbols")
        case .lookUp:
            return String(localized: "shortcut.macos.lookUp", defaultValue: "Look up & data detectors")
        case .helpMenuSearch:
            return String(localized: "shortcut.macos.helpMenuSearch", defaultValue: "Show Help menu")
        case .focusMenuBar:
            return String(localized: "shortcut.macos.focusMenuBar", defaultValue: "Move focus to the menu bar")
        case .focusDock:
            return String(localized: "shortcut.macos.focusDock", defaultValue: "Move focus to the Dock")
        case .voiceOver:
            return String(localized: "shortcut.macos.voiceOver", defaultValue: "Turn VoiceOver on or off")
        case .accessibilityShortcuts:
            return String(localized: "shortcut.macos.accessibilityShortcuts", defaultValue: "Show Accessibility Shortcuts")
        }
    }
}

/// Plain-text lines describing a keymap preset switch, shared by the Settings
/// row and the Command Palette confirmation.
public enum ShortcutKeymapPlanText {
    /// One line per changed shortcut, then one per macOS conflict, then one per
    /// user binding the preset kept.
    public static func lines(for plan: ShortcutKeymapPlan) -> [String] {
        guard !plan.isEmpty || !plan.kept.isEmpty else {
            return [String(localized: "shortcut.keymap.summary.none", defaultValue: "No shortcuts changed.")]
        }
        let changeFormat = String(localized: "shortcut.keymap.summary.change", defaultValue: "%1$@: %2$@ → %3$@")
        let conflictFormat = String(
            localized: "shortcut.keymap.summary.conflict",
            defaultValue: "%1$@ is also a macOS shortcut (%2$@). macOS may handle it before cmux."
        )
        let keptFormat = String(
            localized: "shortcut.keymap.summary.kept",
            defaultValue: "Kept your own shortcut for %@."
        )
        var lines = plan.changes.map { change in
            String.localizedStringWithFormat(
                changeFormat,
                change.action.displayName,
                display(change.before, for: change.action),
                display(change.after, for: change.action)
            )
        }
        for change in plan.systemConflicts {
            let names = change.systemConflicts.map(\.displayName).joined(separator: ", ")
            lines.append(String.localizedStringWithFormat(
                conflictFormat,
                display(change.after, for: change.action),
                names
            ))
        }
        lines += plan.kept.map { String.localizedStringWithFormat(keptFormat, $0.displayName) }
        return lines
    }

    private static func display(_ shortcut: StoredShortcut, for action: ShortcutAction) -> String {
        guard !shortcut.isUnbound else {
            return String(localized: "shortcut.unbound.displayValue", defaultValue: "None")
        }
        return shortcutDisplayString(shortcut, numbered: action.usesNumberedDigitMatching)
    }
}
