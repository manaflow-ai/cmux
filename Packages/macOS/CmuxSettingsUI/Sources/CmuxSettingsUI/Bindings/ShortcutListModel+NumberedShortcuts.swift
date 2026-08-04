import CmuxSettings

extension ShortcutListModel {
    /// Normalizes a numbered action's digit to its persisted lower-bound placeholder.
    func normalizedNumberedShortcutIfNeeded(
        _ shortcut: StoredShortcut,
        for action: ShortcutAction
    ) -> StoredShortcut? {
        guard let numberedDigitRange = action.numberedDigitRange else {
            return shortcut
        }
        let digitStroke = shortcut.second ?? shortcut.first
        guard let digit = Int(digitStroke.key), numberedDigitRange.contains(digit) else {
            return nil
        }
        let placeholder = String(numberedDigitRange.lowerBound)
        if let second = shortcut.second {
            return StoredShortcut(
                first: shortcut.first,
                second: ShortcutStroke(
                    key: placeholder,
                    command: second.command,
                    shift: second.shift,
                    option: second.option,
                    control: second.control,
                    keyCode: second.keyCode
                )
            )
        }
        return StoredShortcut(
            first: ShortcutStroke(
                key: placeholder,
                command: shortcut.first.command,
                shift: shortcut.first.shift,
                option: shortcut.first.option,
                control: shortcut.first.control,
                keyCode: shortcut.first.keyCode
            )
        )
    }
}
