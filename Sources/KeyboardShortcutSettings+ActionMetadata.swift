extension KeyboardShortcutSettings.Action {
    var isSystemWideHotkey: Bool { self == .showHideAllWindows }

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
