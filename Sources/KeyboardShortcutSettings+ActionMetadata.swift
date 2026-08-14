extension KeyboardShortcutSettings.Action {
    var isSystemWideHotkey: Bool { self == .showHideAllWindows }

    var allowsChordShortcut: Bool {
        self != .showHideAllWindows
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
