import CmuxNextActions
import Testing

/// The palette resolves every key-down against its own entries of the
/// binding table. That table is now built once per binding change
/// (`RegistryKeyBindings.subtable`) instead of on every keystroke, so it
/// must still follow a rebind, a removal and a keybindings.json entry.
@MainActor @Suite struct PaletteSubtableFollowsBindingsTests {
    static func keep(_ binding: KeyBinding) -> Bool { binding.command == "commandPaletteNext" }

    @Test func aRebindReachesTheCachedSubtable() {
        let registry = ActionRegistry.standard()
        let before = RegistryKeyBindings(registry).subtable("test") { Self.keep($0) }
        #expect(before.entries.contains { $0.keys == [Shortcut("n", modifiers: [.control])] })
        registry.setShortcutOverride(Shortcut("j", modifiers: [.control]), for: "commandPaletteNext")
        let after = RegistryKeyBindings(registry).subtable("test") { Self.keep($0) }
        #expect(after.entries.contains { $0.keys == [Shortcut("j", modifiers: [.control])] })
        #expect(!after.entries.contains { $0.keys == [Shortcut("n", modifiers: [.control])] })
    }

    @Test func aRemovalReachesTheCachedSubtable() {
        let registry = ActionRegistry.standard()
        _ = RegistryKeyBindings(registry).subtable("test") { Self.keep($0) }
        KeyBindingLoader(registry).load(KeyBindingLayers(removals: [KeyBindingRemoval(command: "commandPaletteNext")]))
        #expect(RegistryKeyBindings(registry).subtable("test") { Self.keep($0) }.entries.isEmpty)
    }

    @Test func theSubtableIsTheTablesEntriesFiltered() {
        let registry = ActionRegistry.standard()
        let bindings = RegistryKeyBindings(registry)
        #expect(bindings.subtable("test") { Self.keep($0) }.entries == bindings.table.entries.filter(Self.keep))
    }
}
