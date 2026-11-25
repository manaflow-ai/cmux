/// The registry's chord lookup tables (single keys resolve through
/// `bindingTable`), rebuilt when a binding changes
/// (`ActionRegistry.currentShortcutIndex()`).
nonisolated struct ShortcutIndex {
    /// Chords by first key, then second key.
    var chords: [Shortcut: [Shortcut: [ActionID]]] = [:]
    /// Numbered-family chords by first key, then the second key's `1`.
    var chordDigitFamilies: [Shortcut: [Shortcut: [ActionID]]] = [:]
    /// The binding table built from the same bindings (`RegistryKeyBindings.table`).
    var bindingTable: KeyBindingTable?
    /// Whether `bindingTable` holds the workspaces-as-tabs keys: a table built with the other answer
    /// is rebuilt (`ActionRegistry.includesWorkspaceTabKeys` follows a Debug tunable).
    var bindingTableHasWorkspaceTabKeys = false
    /// Tables derived from `bindingTable` by a filter (`RegistryKeyBindings.subtable`), by name;
    /// dropped with it.
    var subtables: [String: KeyBindingTable] = [:]
    /// Each action's keycaps as read since the last binding change (`ActionRegistry.shortcutKeycaps`), nil for one
    /// with no shortcut: a read walks every override and alternate, and the palette reads every action per open.
    var keycaps: [ActionID: [String]?] = [:]
    /// The localized bundle the kept keycaps were read in: the Space key's word follows the app's language,
    /// which can change live, so other language drops them.
    var keycapsBundle: String?
}
