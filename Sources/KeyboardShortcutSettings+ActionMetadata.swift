import CmuxSettings

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
        if let numberedDigitRange {
            let formatter = ShortcutDisplayFormatter()
            let rangeHint = formatter.numberedDigitRangeHint(for: numberedDigitRange)
            if let secondStroke = shortcut.secondStroke,
               formatter.isNumberedDigitKey(secondStroke.key, in: numberedDigitRange) {
                return shortcut.numberedDigitHintPrefix + rangeHint
            }
            if formatter.isNumberedDigitKey(shortcut.firstStroke.key, in: numberedDigitRange) {
                return shortcut.firstStroke.modifierDisplayString + rangeHint
            }
        }
        return shortcut.displayString
    }
}
