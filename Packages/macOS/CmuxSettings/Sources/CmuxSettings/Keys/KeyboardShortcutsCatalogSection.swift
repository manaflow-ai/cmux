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

    /// Optional leader/prefix stroke for the cmux-owned chord layer.
    /// ``StoredShortcut/unbound`` is the default-off value; the prefix itself
    /// is always a single stroke and action chords remain in ``bindings``.
    public let prefix = JSONKey<StoredShortcut>(
        id: "shortcuts.prefix",
        defaultValue: .unbound
    )

    /// Readable alias for callers that describe the setting as a prefix key.
    /// This is a computed alias so the catalog still exposes one persisted key.
    public var prefixKey: JSONKey<StoredShortcut> { prefix }

    /// The persisted user bindings: `[actionID: StoredShortcut]`.
    /// Actions absent from this dictionary fall back to the layer's
    /// declared default. ``StoredShortcut/unbound`` for an action
    /// represents an explicit "no shortcut" override.
    public let bindings = JSONKey<[String: StoredShortcut]>(
        id: "shortcuts.bindings",
        defaultValue: [:]
    )

    /// Read projection that preserves every managed action ID even when its
    /// binding is malformed. Derived from ``bindings`` so the catalog retains
    /// one stored declaration for the `shortcuts.bindings` path.
    public var bindingSnapshot: JSONKey<ShortcutBindingsSnapshot> {
        JSONKey(
            id: bindings.id,
            defaultValue: ShortcutBindingsSnapshot(
                bindings: [:],
                managedActionIDs: []
            )
        )
    }

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
