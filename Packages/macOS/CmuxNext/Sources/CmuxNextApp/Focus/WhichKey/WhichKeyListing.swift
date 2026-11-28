import CmuxNextActions

/// The which-key overlay's rows: one per key under an armed prefix
/// (`KeyBindingTable.nextKeys`), ordered by key. Where several actions share
/// a key, the one that key would run now is listed, else the first; a key
/// that leads to longer chords reads "more keys" unless it also runs one.
enum WhichKeyListing {
    static func rows(after keys: [Shortcut], table: KeyBindingTable, context: KeyContext, isRunnable: (ActionID) -> Bool,
                     registry: ActionRegistry) -> [WhichKeyRow] {
        // An action unavailable up front (a preview feature that is off, a
        // missing capability) is not offered; one this focus cannot run is
        // listed dimmed.
        table.nextKeys(after: keys, in: context, isRunnable: isRunnable).filter { next in
            next.binding.map { registry.unavailableReason(for: $0.command) == nil } ?? true
        }.map { next in
            let isDigitFamily = next.binding?.argument != nil && next.key.key == "1"
            let key = isDigitFamily ? (next.key.modifierGlyphs + ["1…9"]).joined() : next.key.displayString
            let ranHere = next.binding.map { isRunnable($0.command) && $0.applies(in: context) } ?? false
            let title = next.continues && !ranHere ? WhichKeyStrings.moreKeys
                : next.binding.map { registry.title(for: $0.command) ?? $0.command.rawValue } ?? WhichKeyStrings.moreKeys
            return WhichKeyRow(key: key, title: title, isEnabled: next.isRunnable)
        }.sorted { ($0.key.lowercased(), $0.title) < ($1.key.lowercased(), $1.title) }
    }

    /// The rows under a single-key `prefix` with the registry's process-wide
    /// context (the leader's defaults, tests).
    static func rows(after prefix: Shortcut, in registry: ActionRegistry) -> [WhichKeyRow] {
        let bindings = RegistryKeyBindings(registry)
        let context = KeyContext(bits: registry.context)
        return rows(after: [prefix], table: bindings.table, context: context,
                    isRunnable: { bindings.canPerform($0, in: context.bits) }, registry: registry)
    }
}
