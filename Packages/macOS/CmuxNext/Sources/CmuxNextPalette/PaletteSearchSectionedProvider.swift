/// One of Search's providers (plans/cmux-next/sidebar-search.md): it passes
/// another provider's rows through under its own id, shows them only once the
/// user types (the empty query is Recent) unless asked to (the Chats & agents
/// scope lists its chats at once), and puts them in ``section``: always
/// (`replacesSections`, so the catalog's per-category sections read as one
/// Commands block) or only for rows with no section of their own.
final class PaletteSearchSectionedProvider: PaletteProvider {
    let id: String
    let showsItemsForEmptyQuery: Bool
    private let base: any PaletteProvider
    private let section: PaletteSection?
    private let replacesSections: Bool

    init(_ base: any PaletteProvider, id: String? = nil, section: PaletteSection?, replacesSections: Bool = false,
         showsItemsForEmptyQuery: Bool = false) {
        self.base = base
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
        self.id = id ?? base.id
        self.section = section
        self.replacesSections = replacesSections
    }

    // Released inside an action's task-local scope or a search task, like every provider (#17590).
    nonisolated deinit {}

    var immediateItems: [PaletteItem]? { base.immediateItems.map(sectioned) }
    var refreshesOnOpen: Bool { base.refreshesOnOpen }

    func items() async -> [PaletteItem] { sectioned(await base.items()) }

    private func sectioned(_ items: [PaletteItem]) -> [PaletteItem] {
        guard let section else { return items }
        return items.map { item in
            guard replacesSections || item.section.id == PaletteSection.results.id else { return item }
            var item = item
            item.section = section
            return item
        }
    }
}
