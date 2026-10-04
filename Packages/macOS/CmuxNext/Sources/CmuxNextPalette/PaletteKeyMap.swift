public import AppKit
public import CmuxNextActions
import Foundation

/// Key bindings inside the palette. Next and previous also honor the
/// registry's (user-editable) Palette Next/Previous shortcuts.
public struct PaletteKeyMap {
    public init() {}
    /// `selectedTogglesInPlace`: the selected row's primary command keeps
    /// the palette open (a toggle), so Space with an empty query toggles it.
    public static func command(for event: NSEvent, actionsMenuOpen: Bool, queryIsEmpty: Bool, registry: ActionRegistry,
                               selectedTogglesInPlace: Bool = false) -> PaletteKeyCommand? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let pressed = Shortcut(key, modifiers: flags)
        if let next = registry.effectiveShortcut(for: "commandPaletteNext"), next == pressed { return .moveDown }
        if let previous = registry.effectiveShortcut(for: "commandPalettePrevious"), previous == pressed { return .moveUp }
        // List navigation (R85): the list.next / list.previous bindings (Ctrl-J / Ctrl-K by default).
        if listKeys(for: "list.next", in: registry).contains(pressed) { return .moveDown }
        if listKeys(for: "list.previous", in: registry).contains(pressed) { return .moveUp }

        if event.keyCode == 49, flags.isEmpty, queryIsEmpty, selectedTogglesInPlace, !actionsMenuOpen { return .submit }

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

    /// The single-key bindings of a list action in the binding table,
    /// whatever their `when` (the palette is a list).
    static func listKeys(for id: ActionID, in registry: ActionRegistry) -> [Shortcut] {
        RegistryKeyBindings(registry).table.entries.filter { $0.command == id && $0.keys.count == 1 }.map { $0.keys[0] }
    }

    /// Cmd-W, the chord that closes the selected row's object.
    public static func isCloseItem(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}
