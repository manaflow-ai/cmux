import CmuxNextActions

/// The user's palette ranking settings (cmux.json `palette.aliases` and `palette.pins`, cx-9ce.43):
/// an alias names a command, and pinned commands lead the empty palette.
public nonisolated struct PaletteRankSettings: Sendable, Equatable {
    /// Words by action id: a query that is one of an action's words puts its row first.
    public var aliases: [String: [String]]
    /// Action ids shown first on the empty query, in this order.
    public var pins: [String]
    /// Whether the palette learns from what the person runs (cmux.json `palette.searchHistory`): uses,
    /// learned picks per query start and frecency. Off, nothing is recorded and nothing ranks by it.
    public var remembersSearches: Bool

    public init(aliases: [String: [String]] = [:], pins: [String] = [], remembersSearches: Bool = true) {
        self.aliases = aliases
        self.pins = pins
        self.remembersSearches = remembersSearches
    }
}

extension PaletteRankSettings {
    /// These settings with the catalog's built-in aliases (`ActionDescriptor.paletteAliases`)
    /// added after the user's own words for the same action.
    public func addingBuiltInAliases() -> PaletteRankSettings {
        var merged = self
        for (id, words) in ActionDescriptor.paletteAliases {
            let own = merged.aliases[id.rawValue] ?? []
            merged.aliases[id.rawValue] = own + words.filter { !own.contains($0) }
        }
        return merged
    }
}
