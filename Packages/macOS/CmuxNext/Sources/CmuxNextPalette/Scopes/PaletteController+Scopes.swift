import CmuxNextDesign

/// The scope graph and the scope prototypes of the palette
/// (plans/cmux-next/palette-scopes.md sections 3.5 and 7).
extension PaletteController {
    /// Reads the scope prototypes (Debug Settings) and the sources into the
    /// model's scope graph. Runs on every open, so a changed tunable
    /// applies on the next open.
    func configureScopes() {
        configureScopes(entry: PaletteTunables.scopeEntry.value, chip: PaletteTunables.scopeChip.value,
                        itemActions: PaletteTunables.itemActions.value)
    }

    func configureScopes(entry: PaletteScopeEntryStyle, chip: PaletteScopeChipStyle, itemActions: PaletteItemActionsStyle) {
        let config = PaletteNavConfig(prefixEntry: entry.prefixEntry, keywordEntry: entry.keywordEntry)
        var scopes = PaletteScopeDescriptor.builtIns(
            tabs: sources.tabs != nil || sources.actionPages["tab.search"] != nil,
            workspaces: sources.workspaces != nil, settings: sources.settings != nil)
        scopes += sources.scopes.map(\.descriptor)
        scopes = Self.applying(sources.scopePrefixes?() ?? [:], to: scopes)
        model.navigation = PaletteNavReducer(graph: PaletteScopeGraph(root: PaletteScopeDescriptor.paletteRoot, scopes: scopes), config: config)
        model.itemActionsAsScope = itemActions == .scope
        model.chipStyle = chip
        model.scopeEntry = entry
    }

    /// A user-assigned prefix replaces the scope's default, and any other
    /// scope that had that character loses it: the user's choice wins
    /// (decision D-PS4). An invalid character is ignored.
    nonisolated static func applying(_ assigned: [PaletteScopeID: String?],
                                     to scopes: [PaletteScopeDescriptor]) -> [PaletteScopeDescriptor] {
        guard !assigned.isEmpty else { return scopes }
        let valid = assigned.filter { $0.value.map(PaletteScopeGraph.isValidPrefix) ?? true }
        let taken = Set(valid.values.compactMap { $0 })
        return scopes.map { scope in
            var scope = scope
            if let choice = valid[scope.id] {
                scope.prefix = choice
            } else if let prefix = scope.prefix, taken.contains(prefix) {
                scope.prefix = nil
            }
            return scope
        }
    }
}

