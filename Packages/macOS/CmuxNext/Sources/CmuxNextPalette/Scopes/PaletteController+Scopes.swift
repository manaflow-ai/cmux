import CmuxNextDesign

/// The scope graph and the scope prototypes of the palette
/// (plans/cmux-next/palette-scopes.md sections 3.5 and 7).
extension PaletteController {
    /// Reads the scope prototypes (Debug Settings) and the sources into the
    /// model's scope graph. Runs on every open, so a changed tunable
    /// applies on the next open.
    func configureScopes() {
        configureScopes(entry: PaletteScopeTunables.entryStyle.value, chip: PaletteScopeTunables.chipStyle.value,
                        itemActions: PaletteScopeTunables.itemActions.value)
    }

    func configureScopes(entry: PaletteScopeEntryStyle, chip: PaletteScopeChipStyle, itemActions: PaletteItemActionsStyle) {
        let config = PaletteNavConfig(prefixEntry: entry.prefixEntry, keywordEntry: entry.keywordEntry)
        var scopes = PaletteScopeCatalog.builtIns(
            tabs: sources.tabs != nil || sources.actionPages["tab.search"] != nil,
            workspaces: sources.workspaces != nil, settings: sources.settings != nil)
        scopes += sources.scopes.map(\.descriptor)
        model.navigation = PaletteNavReducer(graph: PaletteScopeGraph(root: PaletteScopeCatalog.root, scopes: scopes), config: config)
        model.itemActionsAsScope = itemActions == .scope
        model.chipStyle = chip
        model.scopeEntry = entry
    }
}
