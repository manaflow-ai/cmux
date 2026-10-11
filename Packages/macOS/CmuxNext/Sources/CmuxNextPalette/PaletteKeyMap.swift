public import AppKit
public import CmuxNextActions
import Foundation

/// Key bindings inside the palette: the binding table's palette entries
/// (`KeyBindingDefaults.paletteKeys`, the `paletteKey.*` actions, Palette
/// Next/Previous and the list navigation keys), resolved with the palette's
/// state as context keys. A user binding or removal of any of them applies.
public struct PaletteKeyMap {
    public init() {}

    /// The palette command of each action the palette resolves.
    static let commands: [ActionID: PaletteKeyCommand] = [
        "commandPaletteNext": .moveDown, "commandPalettePrevious": .moveUp, "list.next": .moveDown, "list.previous": .moveUp,
        "paletteKey.firstItem": .moveToFirst, "paletteKey.lastItem": .moveToLast,
        "paletteKey.pageUp": .pageUp, "paletteKey.pageDown": .pageDown,
        "paletteKey.submit": .submit, "paletteKey.submitAlternate": .submitAlternate,
        "paletteKey.openActions": .openActions, "paletteKey.closeActions": .closeActions, "paletteKey.toggleActions": .toggleActions,
        "paletteKey.escape": .escape, "paletteKey.enterRow": .enterRow, "paletteKey.leaveLevel": .leaveLevel,
        "paletteKey.back": .back, "paletteKey.filterDeleteBackward": .actionsFilterDeleteBackward, "paletteKey.closeItem": .closeItem,
    ]

    /// The `paletteKey.*` actions (the app binds each to its command).
    public static var paletteKeyActions: [ActionID] { commands.keys.filter { $0.rawValue.hasPrefix("paletteKey.") }.sorted { $0.rawValue < $1.rawValue } }

    /// The palette command an action runs (`paletteKey.*`, Palette Next/Previous, list navigation).
    public static func command(forAction id: ActionID) -> PaletteKeyCommand? { commands[id] }

    /// Keys AppKit names by key code whatever characters the event carries
    /// (keypad Enter is Return).
    static let keysByCode: [UInt16: String] = [
        126: Shortcut.upArrowKey, 125: Shortcut.downArrowKey, 123: Shortcut.leftArrowKey, 124: Shortcut.rightArrowKey,
        116: KeyBindingDefaults.pageUp, 121: KeyBindingDefaults.pageDown, 115: KeyBindingDefaults.home, 119: KeyBindingDefaults.end,
        36: Shortcut.returnKey, 76: Shortcut.returnKey, 48: Shortcut.tabKey, 53: Shortcut.escapeKey, 51: Shortcut.deleteKey,
        49: Shortcut.spaceKey,
    ]

    /// `hierarchical`: the page walks a tree (`PaletteHierarchy`), so Left
    /// and Right move through it where they would not move the caret:
    /// Right from the end of the query enters the selected row, Left from
    /// its start goes up. `selectedTogglesInPlace`: the selected row's
    /// primary command keeps the palette open (a toggle), so Space with an
    /// empty query toggles it.
    public static func command(for event: NSEvent, actionsMenuOpen: Bool, queryIsEmpty: Bool, registry: ActionRegistry,
                               hierarchical: Bool = false, caretAtEnd: Bool = true, caretAtStart: Bool? = nil,
                               selectedTogglesInPlace: Bool = false) -> PaletteKeyCommand? {
        var context = KeyContext(bits: [.paletteOpen])
        context[KeyContext.paletteActionsMenuOpen] = .bool(actionsMenuOpen)
        context[KeyContext.paletteQueryEmpty] = .bool(queryIsEmpty)
        context[KeyContext.paletteHierarchical] = .bool(hierarchical)
        context[KeyContext.paletteCaretAtEnd] = .bool(caretAtEnd)
        context[KeyContext.paletteCaretAtStart] = .bool(caretAtStart ?? queryIsEmpty)
        context[KeyContext.paletteTogglesInPlace] = .bool(selectedTogglesInPlace)
        context[KeyContext.listFocus] = .bool(true)
        let table = KeyBindingTable(RegistryKeyBindings(registry).table.entries.filter { commands[$0.command] != nil })
        for shortcut in shortcuts(for: event) {
            if let winner = table.resolve([shortcut], in: context, isRunnable: { _ in true }).winner {
                return commands[winner.command]
            }
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if actionsMenuOpen, flags.isSubset(of: [.shift]), let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return .actionsFilterAppend(characters)
        }
        return nil
    }

    /// The table keys an event may be: its key-code key, else its characters.
    static func shortcuts(for event: NSEvent) -> [Shortcut] {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if let key = keysByCode[event.keyCode] { return [Shortcut(key, modifiers: flags)] }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return [] }
        return [Shortcut(key, modifiers: flags)]
    }

    /// Cmd-W, the chord that closes the selected row's object.
    public static func isCloseItem(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}
