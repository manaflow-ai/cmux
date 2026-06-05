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

    public init() {}
}
