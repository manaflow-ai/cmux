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

    if nextShortcut?.hasChord == false,
       nextShortcut?.matches(
        keyCode: keyCode,
        modifierFlags: flags,
        eventCharacter: chars,
        layoutCharacterProvider: layoutCharacterProvider
    ) == true {
        return 1
    }

    if previousShortcut?.hasChord == false,
       previousShortcut?.matches(
        keyCode: keyCode,
        modifierFlags: flags,
        eventCharacter: chars,
        layoutCharacterProvider: layoutCharacterProvider
    ) == true {
        return -1
    }

    return nil
}

@MainActor
func commandPaletteSelectionDeltaForFieldEditorCommand(
    _ commandSelector: Selector,
    event: NSEvent?,
    nextShortcut: StoredShortcut? = KeyboardShortcutSettings.shortcutIfBound(for: .commandPaletteNext),
    previousShortcut: StoredShortcut? = KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious),
    layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> Int? {
    let selectorDelta: Int
    switch commandSelector {
    case #selector(NSResponder.moveDown(_:)):
        selectorDelta = 1
    case #selector(NSResponder.moveUp(_:)):
        selectorDelta = -1
    default:
        return nil
    }

    guard let event else {
        return selectorDelta
    }

    if let eventDelta = commandPaletteSelectionDeltaForKeyboardNavigation(
        flags: event.modifierFlags,
        chars: event.characters ?? event.charactersIgnoringModifiers ?? "",
        keyCode: event.keyCode,
        nextShortcut: nextShortcut,
        previousShortcut: previousShortcut,
        layoutCharacterProvider: layoutCharacterProvider
    ),
       eventDelta == selectorDelta {
        return eventDelta
    }

    return nil
}
