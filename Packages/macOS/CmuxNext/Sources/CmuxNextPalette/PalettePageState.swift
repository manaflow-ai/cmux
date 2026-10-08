/// Per-page state kept on the navigation stack.
final class PageState {
    enum Kind {
        case list(PalettePageSpec)
        case textInput(PaletteTextInputSpec)
    }

    let kind: Kind
    /// The navigation level that shows this page (`PaletteNavLevel.id`).
    var levelID = 0
    /// The level's generation this page last searched for.
    var generation = 0
    /// Created while another level was on top: load its providers when it
    /// is first shown.
    var needsLoad = true
    var query = ""
    var providerItems: [String: [PaletteItem]] = [:]
    var pendingProviders = Set<String>()
    var tasks: [Task<Void, Never>] = []
    /// Rows last shown on this page, restored instantly when the page comes
    /// back into view (popping) while a fresh search runs.
    var lastSections: [PaletteResultSection]?
    /// Item last reported to the page's `onHighlight`.
    /// False until the page reported its first highlight: the row selected
    /// when the page opens is not a choice yet, so it previews nothing.
    var hasInitialHighlight = false
    var highlightedItemID: String?
    /// A closing command of this page ran: leaving it is not a cancel.
    var committed = false

    /// Merged provider items, their section table, and the Sendable search
    /// entries handed to the searcher. `version` bumps on every rebuild so
    /// the searcher rebuilds its index only when items change.
    private(set) var items: [PaletteItem] = []
    private(set) var sections: [PaletteSection] = []
    private(set) var entries: [PaletteSearchEntry] = []
    private(set) var version = 0
    /// Versions are unique across pages: the searcher keeps one index and
    /// must never mistake another page's snapshot for this one.
    private static var versionCounter = 0

    init(kind: Kind) {
        self.kind = kind
    }

    var title: String {
        switch kind {
        case .list(let page): page.title
        case .textInput(let spec): spec.title
        }
    }

    var symbol: String {
        switch kind {
        case .list(let page): page.symbol
        case .textInput(let spec): spec.symbol
        }
    }

    /// The page's empty-query row (Search Tabs: the previous tab).
    var emptyQuerySelection: Int? {
        guard case .list(let page) = kind else { return nil }
        if let id = page.emptyQuerySelectionID,
           let index = lastSections?.flatMap(\.rows).firstIndex(where: { $0.id == id }) { return index }
        return page.emptyQuerySelection > 0 ? page.emptyQuerySelection : nil
    }

    var sectionOrders: [Int] { sections.map(\.order) }

    /// Merges provider items in provider order, dropping duplicate IDs.
    func rebuild() {
        guard case .list(let page) = kind else { return }
        var items: [PaletteItem] = []
        var entries: [PaletteSearchEntry] = []
        var sections: [PaletteSection] = []
        var sectionIndexByID: [String: Int] = [:]
        var seen = Set<String>()
        for provider in page.providers {
            for item in providerItems[provider.id] ?? [] where seen.insert(item.id).inserted {
                let sectionIndex: Int
                if let existing = sectionIndexByID[item.section.id] {
                    sectionIndex = existing
                } else {
                    sectionIndex = sections.count
                    sectionIndexByID[item.section.id] = sectionIndex
                    sections.append(item.section)
                }
                items.append(item)
                entries.append(PaletteSearchEntry(item, visible: provider.showsItemsForEmptyQuery && item.queryPrefix == nil,
                                                  sectionIndex: sectionIndex))
            }
        }
        self.items = items
        self.entries = entries
        self.sections = sections
        Self.versionCounter += 1
        version = Self.versionCounter
    }

    /// Maps ranked indices back to items for display.
    func resolve(_ ranked: [PaletteRankedSection]) -> [PaletteResultSection] {
        ranked.map { section in
            PaletteResultSection(
                section: section.sectionIndex.map { sections[$0] } ?? .recent,
                rows: section.rows.map { PaletteRow(item: items[$0.index], highlights: $0.highlights, score: $0.score) }
            )
        }
    }

    func cancel() {
        for task in tasks { task.cancel() }
        tasks = []
    }
}
