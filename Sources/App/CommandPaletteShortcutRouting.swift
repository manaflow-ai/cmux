import AppKit

func commandPaletteSelectionDeltaForKeyboardNavigation(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    nextShortcut: StoredShortcut? = KeyboardShortcutSettings.shortcutIfBound(for: .commandPaletteNext),
    previousShortcut: StoredShortcut? = KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious),
    layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> Int? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])

    if normalizedFlags == [] {
        switch keyCode {
        case 125: return 1    // Down arrow
        case 126: return -1   // Up arrow
        default: break
        }
    }

    if nextShortcut?.matches(
        keyCode: keyCode,
        modifierFlags: flags,
        eventCharacter: chars,
        layoutCharacterProvider: layoutCharacterProvider
    ) == true {
        return 1
    }

    if previousShortcut?.matches(
        keyCode: keyCode,
        modifierFlags: flags,
        eventCharacter: chars,
        layoutCharacterProvider: layoutCharacterProvider
    ) == true {
        return -1
    }

    return nil
}
