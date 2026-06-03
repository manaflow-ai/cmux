import Foundation

/// Settings under the dotted-id prefix `shortcuts.*`.
///
/// Everything user-customisable about keyboard shortcuts lives behind a
/// single JSON-backed key: a dictionary mapping each action's stable id
/// to the user's stored binding. The action catalog itself (display
/// names, defaults, search keywords) belongs to the
/// `CmuxKeyboardShortcuts` layer that consumes this catalog; this
/// section is intentionally minimal and purely declarative.
public struct KeyboardShortcutsCatalogSection: SettingCatalogSection {
    /// The persisted user bindings: `[actionID: StoredShortcut]`.
    /// Actions absent from this dictionary fall back to the layer's
    /// declared default. ``StoredShortcut/unbound`` for an action
    /// represents an explicit "no shortcut" override.
    public let bindings = JSONKey<[String: StoredShortcut]>(
        id: "shortcuts.bindings",
        defaultValue: [:]
    )

    /// Per-action focus predicates (`shortcuts.when`), keyed by action id, as
    /// raw expression strings. The app target owns parsing/evaluation; the
    /// Settings UI only needs to know which actions are context-scoped so its
    /// conflict detection does not false-reject two bindings the user has made
    /// disjoint by context.
    public let when = JSONKey<[String: String]>(
        id: "shortcuts.when",
        defaultValue: [:]
    )

    public init() {}
}
