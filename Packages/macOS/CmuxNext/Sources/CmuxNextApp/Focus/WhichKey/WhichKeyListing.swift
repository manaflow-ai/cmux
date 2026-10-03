import CmuxNextActions

/// One row of the which-key overlay: the key after the leader and the
/// action it runs.
struct WhichKeyRow: Equatable {
    var key: String
    var title: String
    /// False when the action cannot run in this focus (drawn dimmed).
    var isEnabled: Bool
}

/// The which-key overlay's rows: one per key bound under a chord prefix
/// (`LeaderLayer.chords(after:)`), ordered by key. Where several actions
/// share a key, the one that key would run now is listed, else the first.
enum WhichKeyListing {
    static func rows(after prefix: Shortcut, in registry: ActionRegistry) -> [WhichKeyRow] {
        Dictionary(grouping: LeaderLayer(registry: registry).chords(after: prefix), by: \.second).map { second, bindings in
            let id = registry.resolveChord(after: prefix, second)?.id ?? bindings[0].id
            return WhichKeyRow(key: registry.shortcutDisplay(second, for: id), title: registry.title(for: id) ?? id.rawValue,
                               isEnabled: registry.canPerform(id))
        }.sorted { ($0.key.lowercased(), $0.title) < ($1.key.lowercased(), $1.title) }
    }
}

/// The overlay's own text (WhichKey.xcstrings).
enum WhichKeyStrings {
    static var cancelHint: String {
        String(localized: "whichKey.cancelHint", defaultValue: "esc to cancel", table: "WhichKey", bundle: .module)
    }

    static var accessibilityLabel: String {
        String(localized: "whichKey.accessibilityLabel", defaultValue: "Leader keys", table: "WhichKey", bundle: .module)
    }
}
