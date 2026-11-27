import AppKit

func commandPaletteSelectionDeltaForKeyboardNavigation(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    nextShortcut: StoredShortcut?,
    previousShortcut: StoredShortcut?,
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
func commandPaletteSelectionDeltaForKeyboardNavigation(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16,
    layoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> Int? {
    commandPaletteSelectionDeltaForKeyboardNavigation(
        flags: flags,
        chars: chars,
        keyCode: keyCode,
        nextShortcut: KeyboardShortcutSettings.shortcutIfBound(for: .commandPaletteNext),
        previousShortcut: KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious),
        layoutCharacterProvider: layoutCharacterProvider
    )
}

@MainActor
func contextAwareCommandPaletteSelectionDelta(
    for event: NSEvent
) -> Int? {
    let normalizedFlags = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
    if normalizedFlags.isEmpty {
        switch event.keyCode {
        case 125: return 1
        case 126: return -1
        default: break
        }
    }

    let characters = event.characters ?? event.charactersIgnoringModifiers ?? ""
    for (action, delta) in [
        (KeyboardShortcutSettings.Action.commandPaletteNext, 1),
        (.commandPalettePrevious, -1),
    ] {
        guard let shortcut = KeyboardShortcutSettings.shortcutIfBound(for: action),
              !shortcut.hasChord,
              shortcut.matches(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                eventCharacter: characters,
                layoutCharacterProvider: KeyboardLayout.character(forKeyCode:modifierFlags:)
              ),
              AppDelegate.shared?.shortcutWhenClauseAllows(action: action, event: event) != false else { continue }
        return delta
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
        let shortcut = selectorDelta == 1 ? nextShortcut : previousShortcut
        let defaultShortcut = selectorDelta == 1
            ? KeyboardShortcutSettings.Action.commandPaletteNext.defaultShortcut
            : KeyboardShortcutSettings.Action.commandPalettePrevious.defaultShortcut
        return shortcut == defaultShortcut ? selectorDelta : nil
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
