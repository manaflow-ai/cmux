/// The registry's key lookup tables, rebuilt when a binding changes
/// (`ActionRegistry.currentShortcutIndex()`).
nonisolated struct ShortcutIndex {
    var byShortcut: [Shortcut: [ActionID]] = [:]
    var digitFamilies: [Shortcut: [ActionID]] = [:]
    /// Chords by first key, then second key.
    var chords: [Shortcut: [Shortcut: [ActionID]]] = [:]
    /// Numbered-family chords by first key, then the second key's `1`.
    var chordDigitFamilies: [Shortcut: [Shortcut: [ActionID]]] = [:]
    /// The binding table built from the same bindings (`RegistryKeyBindings.table`).
    var bindingTable: KeyBindingTable?
}
