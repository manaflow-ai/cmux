extension KeyboardShortcutSettings.Action {
    func tooltip(_ base: String) -> String {
        "\(base) (\(displayedShortcutString(for: KeyboardShortcutSettings.shortcut(for: self))))"
    }

    var usesNumberedDigitMatching: Bool {
        switch self {
        case .selectSurfaceByNumber, .selectWorkspaceByNumber:
            return true
        default:
            return false
        }
    }

    var allowsChordShortcut: Bool {
        self != .fileExplorerOpenSelection
            && self != .fileExplorerOpenSelectionFinderAlias
            && self != .cycleTextBoxSubmitAction
    }

    func displayedShortcutString(for shortcut: StoredShortcut) -> String {
        if shortcut.isUnbound {
            return shortcut.displayString
        }
        if usesNumberedDigitMatching {
            return shortcut.numberedDisplayString
        }
        return shortcut.displayString
    }
}
