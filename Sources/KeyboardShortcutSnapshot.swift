struct KeyboardShortcutSnapshot: Equatable, Sendable {
    private let shortcuts: [KeyboardShortcutSettings.Action: StoredShortcut]

    static let defaults = KeyboardShortcutSnapshot(
        shortcuts: Dictionary(
            uniqueKeysWithValues: KeyboardShortcutSettings.Action.allCases.map {
                ($0, $0.defaultShortcut)
            }
        )
    )

    static func load(
        using provider: @Sendable (KeyboardShortcutSettings.Action) -> StoredShortcut
    ) -> KeyboardShortcutSnapshot {
        KeyboardShortcutSnapshot(
            shortcuts: Dictionary(
                uniqueKeysWithValues: KeyboardShortcutSettings.Action.allCases.map {
                    ($0, provider($0))
                }
            )
        )
    }

    func shortcut(for action: KeyboardShortcutSettings.Action) -> StoredShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }
}
