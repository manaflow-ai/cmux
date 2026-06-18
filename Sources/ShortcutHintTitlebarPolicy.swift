enum ShortcutHintTitlebarPolicy {
    static func shouldShow(
        shortcut: StoredShortcut,
        alwaysShowShortcutHints: Bool,
        modifierPressed: Bool,
        modifierHoldHintsEnabled: Bool = true
    ) -> Bool {
        !shortcut.isUnbound && (alwaysShowShortcutHints || (modifierHoldHintsEnabled && shortcut.command && modifierPressed))
    }
}
