import AppKit

enum ShortcutHintTitlebarPolicy {
    static func shouldShow(
        shortcut: StoredShortcut,
        alwaysShowShortcutHints: Bool,
        modifierPressed: Bool,
        modifierHoldHintsEnabled: Bool = true
    ) -> Bool {
        shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierFlags: modifierPressed ? [.command] : [],
            modifierHoldHintsEnabled: modifierHoldHintsEnabled
        )
    }

    static func shouldShow(
        shortcut: StoredShortcut,
        alwaysShowShortcutHints: Bool,
        modifierFlags: NSEvent.ModifierFlags,
        modifierHoldHintsEnabled: Bool = true
    ) -> Bool {
        guard !shortcut.isUnbound else { return false }
        if alwaysShowShortcutHints { return true }
        guard modifierHoldHintsEnabled else { return false }

        switch normalized(modifierFlags) {
        case [.command]:
            return shortcut.command
        case [.control]:
            return shortcut.control
        default:
            return false
        }
    }

    static func modifierHoldHintsEnabled(
        showModifierHoldHints: Bool,
        showCommandHoldHints: Bool,
        heldModifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard showModifierHoldHints else { return false }
        let heldFlags = normalized(heldModifierFlags)
        guard heldFlags.contains(.command) else { return true }
        return showCommandHoldHints
    }

    private static func normalized(_ modifierFlags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }
}
