import Foundation

/// Settings under the dotted-id prefix `shortcuts.*`.
///
/// The binding dictionary stores per-action shortcut overrides, while
/// UserDefaults-backed keys in this section cover app-wide keyboard shortcut
/// presentation preferences. The action catalog itself (display names,
/// defaults, search keywords) belongs to the `CmuxKeyboardShortcuts` layer that
/// consumes this catalog; this section is intentionally minimal and purely
/// declarative.
public struct KeyboardShortcutsCatalogSection: SettingCatalogSection {
    /// Whether holding modifier keys shows shortcut-hint chips in the app UI.
    public let showModifierHoldHints = DefaultsKey<Bool>(
        id: "shortcuts.showModifierHoldHints",
        defaultValue: true,
        userDefaultsKey: "showModifierHoldHints"
    )

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

    /// User-defined shortcuts bound to Command-Palette commands, keyed by the
    /// command's stable id (for example `palette.triggerFlash`). Parallel to
    /// ``bindings`` but addressed by command id rather than action id; the app
    /// target matches these in its shortcut dispatch. ``StoredShortcut/unbound``
    /// represents an explicit "no shortcut" entry.
    public let commands = JSONKey<[String: StoredShortcut]>(
        id: "shortcuts.commands",
        defaultValue: [:]
    )

    public init() {}
}
