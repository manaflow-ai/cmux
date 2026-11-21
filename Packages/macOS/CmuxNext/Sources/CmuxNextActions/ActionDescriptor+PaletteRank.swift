/// How the command palette orders the catalog (plans/cmux-next/palette-ranking.md 5.4, the
/// palette audit). Nothing here hides an action: every action stays a search result, a CLI verb
/// and an MCP tool. A tier moves a row up or down among rows that match a query equally well; a
/// family folds related rows into one row on the empty query, and the members still match when
/// typed. The tables are catalog data in Rust (cmux-action-catalog `palette.rs`).
public nonisolated enum PaletteTier: Int, Sendable, Hashable, Comparable {
    /// Used most days: first in its section, and ahead of an equal match while typing.
    case daily
    case standard
    /// Valid but rarely wanted (an ID copy, a diagnostic, one value of a family): last in its
    /// section, and behind an equal match while typing.
    case niche

    public static func < (lhs: PaletteTier, rhs: PaletteTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Related actions the empty palette shows as one row. With a `parent` (Set Space Color… for the
/// nine colors, Toggle Developer Tools for the Developer Tools commands) the parent's row stands
/// for them; without one the palette draws a row titled `title` that opens a page of the members
/// (Workspace: Move… for the ten moves). A duplicate is a family of one: its row folds into the
/// row people know, which matches its words too.
public nonisolated struct PaletteFamily: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let parent: ActionID?
    public let members: [ActionID]

    init(_ id: String, title: String, symbol: String, members: [ActionID]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        parent = nil
        self.members = members
    }

    init(_ id: String, parent: ActionID, members: [ActionID]) {
        self.id = id
        title = ""
        symbol = ""
        self.parent = parent
        self.members = members
    }
}

extension ActionDescriptor {
    /// Daily commands: what a person reaches for in the palette most days.
    nonisolated static var paletteDailyActions: Set<ActionID> { RustActionCatalog.shared.paletteDaily }

    /// Niche commands: valid, rarely wanted.
    nonisolated static var paletteNicheActions: Set<ActionID> { RustActionCatalog.shared.paletteNiche }

    /// Built-in palette aliases: a query that is one of these words puts the action first (as a
    /// cmux.json `palette.aliases` entry does), and the word matches it as a keyword while typing.
    nonisolated public static var paletteAliases: [ActionID: [String]] { RustActionCatalog.shared.paletteAliases }

    /// The families the empty palette folds into one row each.
    nonisolated public static var paletteFamilies: [PaletteFamily] { RustActionCatalog.shared.paletteFamilies }

    /// Duplicates the palette folds into the row people know (an action offered twice, once as a
    /// menu item), keyed by the duplicate. Both keep their own target, CLI verb and menu
    /// placement, and carry the canonical action's name on every surface
    /// (`PaletteMenuVocabularyTests`).
    nonisolated public static var paletteDuplicates: [ActionID: ActionID] { RustActionCatalog.shared.paletteDuplicates }

    /// The action whose name this one carries: itself unless it is a duplicate.
    nonisolated public var canonicalActionID: ActionID { Self.paletteDuplicates[id] ?? id }

    nonisolated static let paletteFamilyByMember: [ActionID: PaletteFamily] = {
        var byMember: [ActionID: PaletteFamily] = [:]
        for family in paletteFamilies {
            for member in family.members where byMember[member] == nil { byMember[member] = family }
        }
        return byMember
    }()

    /// The family whose row stands for this action on the empty query, or nil.
    nonisolated public var paletteFamily: PaletteFamily? { Self.paletteFamilyByMember[id] }

    nonisolated public var paletteTier: PaletteTier {
        // Debug-only rows ("Debug: <name>", Internal Developer Mode) share one tier, so they keep the
        // catalog's order: last, sorted by name (ActionCatalog `withDebugActionsLast`).
        if isDebugOnly { return .niche }
        if Self.paletteDailyActions.contains(id) { return .daily }
        if Self.paletteNicheActions.contains(id) || paletteFamily != nil { return .niche }
        return .standard
    }
}
