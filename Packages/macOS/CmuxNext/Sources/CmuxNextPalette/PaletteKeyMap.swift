public import AppKit
public import CmuxNextActions
import Foundation

/// Key bindings inside the palette. Next and previous also honor the
/// registry's (user-editable) Palette Next/Previous shortcuts.
public struct PaletteKeyMap {
    public init() {}
    public static func command(for event: NSEvent, actionsMenuOpen: Bool, queryIsEmpty: Bool, registry: ActionRegistry) -> PaletteKeyCommand? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let pressed = Shortcut(key, modifiers: flags)
        if let next = registry.effectiveShortcut(for: "commandPaletteNext"), next == pressed { return .moveDown }
        if let previous = registry.effectiveShortcut(for: "commandPalettePrevious"), previous == pressed { return .moveUp }

        switch event.keyCode {
        case 126: return flags.contains(.command) ? .moveToFirst : .moveUp
        case 125: return flags.contains(.command) ? .moveToLast : .moveDown
        case 116: return .pageUp
        case 121: return .pageDown
        case 115: return actionsMenuOpen ? .moveToFirst : nil
        case 119: return actionsMenuOpen ? .moveToLast : nil
        case 36, 76: return flags.contains(.command) ? .submitAlternate : .submit
        case 48: return flags.contains(.shift) ? .closeActions : .openActions
        case 53: return .escape
        case 51:
            if actionsMenuOpen { return .actionsFilterDeleteBackward }
            return queryIsEmpty ? .back : nil
        default: break
        }
        if flags == .command, key == "k" { return .toggleActions }
        if isCloseItem(event) { return .closeItem }
        if actionsMenuOpen, flags.isSubset(of: [.shift]), let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return .actionsFilterAppend(characters)
        }
        return nil
    }

    /// Cmd-W, the chord that closes the selected row's object.
    public static func isCloseItem(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}
