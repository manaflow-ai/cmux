public import CmuxNextActions

/// The searchable text and ranking inputs of one item. Sendable, so an
/// index can be built and searched off the main actor.
nonisolated public struct PaletteSearchEntry: Sendable, Hashable {
    public var title: String
    public var keywords: [String]
    public var subtitle: String?
    public var accessory: String?
    public var rankBias: Int
    public var frecencyKey: String?
    public var isEnabled: Bool
    public var isVisibleWhenQueryEmpty: Bool
    /// Matches only a query with this prefix (`PaletteItem.queryPrefix`).
    public var queryPrefix: String?
    /// Shows for an empty query only (`PaletteItem.hidesWhenTyping`).
    public var hidesWhenTyping = false
    /// The row enters a scope (`PaletteItem.enters`): a keyword equal to the query ranks it right
    /// after whole-title matches.
    public var entersScope = false
    /// Index into the page's section table.
    public var sectionIndex: Int
    /// The section table index used while typing (`PalettePageSpec.mergesSectionsWhenTyping`), nil for `sectionIndex`.
    public var typingSectionIndex: Int?
    /// The registry action id: a query that is the id, or starts it, finds the row
    /// (`PaletteItem.actionID`). Not a keyword, so ids never match ordinary words.
    public var actionID: String?
    /// `PaletteItem.isDemoted`.
    public var demoted = false
    /// The row has a keyboard shortcut (`PaletteItem.keycaps`): a core command,
    /// ranked first among equal matches.
    public var hasShortcut = false
    /// The keycaps of the row's live shortcut (`PaletteItem.keycaps`, user overrides included):
    /// the ranker ranks the row first for a query that names it ("cmd shift p", "⇧⌘P").
    public var keycaps: [String] = []
    /// `PaletteItem.suggestedRank`, and the Suggested section's index in the page's table.
    public var suggestedRank: Int?
    public var suggestedSectionIndex: Int?
    /// `PaletteItem.handles`.
    public var handles: [String] = []

    public init(
        title: String,
        keywords: [String] = [],
        subtitle: String? = nil,
        accessory: String? = nil,
        rankBias: Int = 0,
        frecencyKey: String? = nil,
        isEnabled: Bool = true,
        isVisibleWhenQueryEmpty: Bool = true,
        queryPrefix: String? = nil,
        sectionIndex: Int = 0
    ) {
        self.title = title
        self.keywords = keywords
        self.subtitle = subtitle
        self.accessory = accessory
        self.rankBias = rankBias
        self.frecencyKey = frecencyKey
        self.isEnabled = isEnabled
        self.isVisibleWhenQueryEmpty = isVisibleWhenQueryEmpty
        self.queryPrefix = queryPrefix
        self.sectionIndex = sectionIndex
    }
}

/// The search candidates of one page, as the shared TypeScript ranker
/// (`PaletteRankerBridge`) takes them. A value type, so the main actor hands
/// a snapshot to the searcher and never shares mutable state.
nonisolated public struct PaletteSearchIndex: Sendable {
    public let entries: [PaletteSearchEntry]

    public init(entries: [PaletteSearchEntry]) {
        self.entries = entries
    }

    public var count: Int { entries.count }
}

extension PaletteSearchIndex {
    /// Builds an index over `items`; sections are numbered in first-seen order.
    @MainActor
    public init(items: [PaletteItem], visibleWhenQueryEmpty: [Bool]? = nil) {
        var sectionIndexByID: [String: Int] = [:]
        let entries = items.enumerated().map { position, item in
            let sectionIndex = sectionIndexByID[item.section.id] ?? {
                let next = sectionIndexByID.count
                sectionIndexByID[item.section.id] = next
                return next
            }()
            return PaletteSearchEntry(item, visible: visibleWhenQueryEmpty?[position] ?? true, sectionIndex: sectionIndex)
        }
        self.init(entries: entries)
    }
}

extension PaletteSearchEntry {
    /// The localized keycap of the space key (`Shortcut.keyGlyph`).
    @MainActor private static let spaceKeycap = Shortcut(Shortcut.spaceKey, modifiers: []).keyGlyph

    @MainActor
    init(_ item: PaletteItem, visible: Bool, sectionIndex: Int) {
        self.init(
            title: item.title,
            keywords: item.keywords,
            subtitle: item.subtitle,
            accessory: item.accessory,
            rankBias: item.rankBias,
            frecencyKey: item.frecencyKey,
            isEnabled: item.isEnabled,
            isVisibleWhenQueryEmpty: visible,
            queryPrefix: item.queryPrefix,
            sectionIndex: sectionIndex
        )
        hidesWhenTyping = item.hidesWhenTyping
        entersScope = item.enters != nil
        actionID = item.actionID?.rawValue
        demoted = item.isDemoted
        // The space key's keycap is localized ("Space"); the ranker reads a locale-free "␣".
        keycaps = (item.keycaps ?? []).map { $0 == Self.spaceKeycap ? "␣" : $0 }
        hasShortcut = !keycaps.isEmpty
        suggestedRank = item.suggestedRank
        handles = item.handles
    }
}
