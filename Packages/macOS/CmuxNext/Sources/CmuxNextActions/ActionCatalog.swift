/// The canonical action catalog: every descriptor, read once from Rust
/// (cmux-tui/crates/cmux-action-catalog, `RustActionCatalog`), in catalog order (menu ranks
/// tie-break on it). IDs match `KeyboardShortcutSettings.Action` raw values where one existed
/// (users store them in `cmux.json` `shortcuts`), else the old palette command ID, else a new
/// stable ID. The handlers bind to these IDs in the App.
public nonisolated enum ActionCatalog {
    /// Every catalog descriptor, in catalog order.
    /// Stored, as the Swift catalog's was: objects built against either declaration link (a computed
    /// `all` has no addressor, so a warm build's stale test objects failed to link).
    public static let all: [ActionDescriptor] = RustActionCatalog.shared.descriptors

    /// IDs from before the catalog or renamed since, mapped to their canonical catalog ID. The
    /// registry folds these on register and lookup so older call sites, keybindings and scripts
    /// keep working.
    public static let legacyAliases: [ActionID: ActionID] = RustActionCatalog.shared.legacyAliases

    /// The descriptors one catalog group declares (`AppStoreActionCatalog`, ...), in catalog order.
    static func descriptors(inGroup group: String) -> [ActionDescriptor] {
        let groupOf = RustActionCatalog.shared.groupOf
        return all.filter { groupOf[$0.id] == group }
    }
}

extension ActionRegistry {
    /// A registry seeded with the full cmux catalog and legacy aliases whose runs are not timed.
    ///
    /// A separate symbol, not a default argument of ``standard(runTiming:)``: objects compiled
    /// before the timing was injected call this one (warm fleet build trees link them).
    public static func standard() -> ActionRegistry {
        standard(runTiming: NoActionRunTiming())
    }

    /// A registry seeded with the full cmux catalog and legacy aliases.
    ///
    /// - Parameter runTiming: Times every run (the App passes ``SignpostActionRunTiming``).
    public static func standard(runTiming: any ActionRunTiming) -> ActionRegistry {
        ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases, runTiming: runTiming)
    }
}
