import CmuxSettings

extension ShortcutListModel {
    /// Normalizes a numbered action's digit to the persisted `1` placeholder.
    func normalizedNumberedShortcutIfNeeded(
        _ shortcut: StoredShortcut,
        for action: ShortcutAction
    ) -> StoredShortcut? {
        guard action.usesNumberedDigitMatching else {
            return shortcut
        }
        let digitStroke = shortcut.second ?? shortcut.first
        guard isNumberedDigitKey(digitStroke.key) else {
            return nil
        }
        if let second = shortcut.second {
            return StoredShortcut(
                first: shortcut.first,
                second: ShortcutStroke(
                    key: "1",
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
                key: "1",
                command: shortcut.first.command,
                shift: shortcut.first.shift,
                option: shortcut.first.option,
                control: shortcut.first.control,
                keyCode: shortcut.first.keyCode
            )
        )
    }
}
