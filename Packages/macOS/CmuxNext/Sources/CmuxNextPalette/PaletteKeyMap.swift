public import AppKit
public import CmuxNextActions
import Foundation

/// Key bindings inside the palette. Next and previous also honor the
/// registry's (user-editable) Palette Next/Previous shortcuts.
public struct PaletteKeyMap {
    public init() {}
    /// `hierarchical`: the page walks a tree (`PaletteHierarchy`), so Left
    /// and Right move through it where they would not move the caret:
    /// Right from the end of the query enters the selected row, Left from
    /// its start goes up.
    public static func command(for event: NSEvent, actionsMenuOpen: Bool, queryIsEmpty: Bool, registry: ActionRegistry,
                               hierarchical: Bool = false, caretAtEnd: Bool = true, caretAtStart: Bool? = nil) -> PaletteKeyCommand? {
        let caretAtStart = caretAtStart ?? queryIsEmpty
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let pressed = Shortcut(key, modifiers: flags)
        if let next = registry.effectiveShortcut(for: "commandPaletteNext"), next == pressed { return .moveDown }
        if let previous = registry.effectiveShortcut(for: "commandPalettePrevious"), previous == pressed { return .moveUp }

        switch event.keyCode {
        // Cmd-Up: a tree page's parent, else the first row.
        case 126 where hierarchical && !actionsMenuOpen && flags == .command: return .leaveLevel
        case 126: return flags.contains(.command) ? .moveToFirst : .moveUp
        case 125: return flags.contains(.command) ? .moveToLast : .moveDown
        case 116: return .pageUp
        case 121: return .pageDown
        // Home and End: the Actions menu's ends, or a tree page's with an
        // empty query (otherwise they move the caret).
        case 115: return actionsMenuOpen || (hierarchical && queryIsEmpty) ? .moveToFirst : nil
        case 119: return actionsMenuOpen || (hierarchical && queryIsEmpty) ? .moveToLast : nil
        case 36, 76: return flags.contains(.command) ? .submitAlternate : .submit
        case 48: return flags.contains(.shift) ? .closeActions : .openActions
        case 53: return .escape
        case 124 where hierarchical && !actionsMenuOpen && flags.isEmpty && caretAtEnd: return .enterRow
        case 123 where hierarchical && !actionsMenuOpen && flags.isEmpty && caretAtStart: return .leaveLevel
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
