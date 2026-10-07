import AppKit
@testable import CmuxNextActions
import CmuxNextPalette
import Testing

/// The palette's keys are binding table entries (R59 fold): each palette
/// command is a catalog action whose default keys are table entries with a
/// `when` over the palette's state, so they show on the Keyboard Shortcuts
/// page and a user can rebind or remove them like any other key.
@MainActor
struct PaletteKeyBindingTests {
    static func key(_ code: UInt16, _ chars: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func paletteKeysAreTableEntriesForPaletteActions() {
        let registry = ActionRegistry.standard()
        let entries = RegistryKeyBindings(registry).table.entries
        // Decision K1: the Actions menu has no default key of its own (Tab opens it).
        #expect(!entries.contains { $0.command == "paletteKey.toggleActions" })
        let tab = entries.first { $0.command == "paletteKey.openActions" }
        #expect(tab?.when?.text.contains("paletteOpen") == true)
        for id: ActionID in ["paletteKey.submit", "paletteKey.escape", "paletteKey.openActions", "paletteKey.closeItem", "paletteKey.firstItem"] {
            #expect(registry.descriptor(for: id) != nil, "\(id) is a catalog action")
            #expect(entries.contains { $0.command == id }, "\(id) has a default key")
        }
    }

    @Test func aUserRebindingMovesAPaletteKey() {
        let registry = ActionRegistry.standard()
        registry.keyBindingLayers = KeyBindingLayers(
            user: [KeyBinding(keys: [Shortcut("j", modifiers: [.command])], command: "paletteKey.toggleActions", source: .user)],
            removals: [KeyBindingRemoval(command: "paletteKey.toggleActions", keys: [Shortcut("k", modifiers: [.command])])])
        #expect(PaletteKeyMap.command(for: Self.key(38, "j", .command), actionsMenuOpen: false, queryIsEmpty: true, registry: registry)
            == .toggleActions)
        #expect(PaletteKeyMap.command(for: Self.key(40, "k", .command), actionsMenuOpen: false, queryIsEmpty: true, registry: registry) == nil)
        // The other palette keys are unchanged.
        #expect(PaletteKeyMap.command(for: Self.key(36, "\r"), actionsMenuOpen: false, queryIsEmpty: true, registry: registry) == .submit)
    }
}
