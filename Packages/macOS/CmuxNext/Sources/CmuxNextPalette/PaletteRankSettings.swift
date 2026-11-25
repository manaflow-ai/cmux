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
    /// The palette experiments the person turned on (`experiments.paletteV2`, `experiments.palettePreview`), read
    /// with the rest of the palette's cmux.json keys on every open.
    public var experiments: PaletteExperiments

    public init(aliases: [String: [String]] = [:], pins: [String] = [], remembersSearches: Bool = true,
                experiments: PaletteExperiments = PaletteExperiments()) {
        self.aliases = aliases
        self.pins = pins
        self.remembersSearches = remembersSearches
        self.experiments = experiments
    }
}

extension PaletteRankSettings {
    /// These settings with the catalog's built-in aliases (`ActionDescriptor.paletteAliases`)
    /// added after the user's own words for the same action. The ranker also reads them from each
    /// catalog row (`PaletteItem.aliases`); this merge serves app FFI pins older than that ranker,
    /// and goes once the pin carries it.
    public func addingBuiltInAliases() -> PaletteRankSettings {
        var merged = self
        for (id, words) in ActionDescriptor.paletteAliases {
            let own = merged.aliases[id.rawValue] ?? []
            merged.aliases[id.rawValue] = own + words.filter { !own.contains($0) }
        }
        return merged
    }
}

/// The palette v2 look (Settings > Experimental > Experiments, `experiments.paletteV2`): results grouped under
/// Workspaces, Sessions, Commands and Agents, regrouped live as the query changes, the top match preselected.
/// Off is today's palette; the person turns a look on, nothing turns it on for them.
public nonisolated enum PaletteV2Look: String, Sendable, CaseIterable {
    /// Today's palette.
    case off
    /// A: one list under small group headers, an Esc chip in the field.
    case flat
    /// B: a category rail on the left (All and each group with its count), the chosen group's rows on the right.
    case rail
    /// C: A plus a scope bar under the field (All, This Workspace, Sessions) and typed tokens ("Session contains: X").
    case scoped

    /// The look a `experiments.paletteV2` value names; anything else is off.
    public init(setting: String?) { self = setting.flatMap(PaletteV2Look.init(rawValue:)) ?? .off }

    public var isOn: Bool { self != .off }
    /// The left category rail.
    public var showsRail: Bool { self == .rail }
    /// The scope bar under the field, with typed tokens.
    public var showsScopeBar: Bool { self == .scoped }
}

/// The palette experiments the person turned on (Settings > Experimental > Experiments), read on every open.
public nonisolated struct PaletteExperiments: Sendable, Equatable {
    /// `experiments.paletteV2`.
    public var look: PaletteV2Look
    /// `experiments.palettePreview`: a detail pane beside the list with the selected workspace's or session's facts,
    /// and a footer pill with the primary action, a Return glyph and "Actions ⌘K".
    public var preview: Bool

    public init(look: PaletteV2Look = .off, preview: Bool = false) {
        self.look = look
        self.preview = preview
    }
}
