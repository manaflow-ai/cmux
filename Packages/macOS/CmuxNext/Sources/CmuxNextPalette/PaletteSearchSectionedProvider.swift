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

    /// Each list of a base that gives its rows in more than one list (a History list that is not complete yet), in ``section``.
    func itemUpdates() -> AsyncStream<[PaletteItem]>? {
        guard let updates = base.itemUpdates() else { return nil }
        let (stream, continuation) = AsyncStream.makeStream(of: [PaletteItem].self, bufferingPolicy: .bufferingNewest(1))
        // task-owner: one open's lists of the base provider; ends with the base's stream or with this stream's consumer
        // main-hop-allow: not an action's work: it awaits the base's stream and sets the section on each list it gives (one map of that list), as `items()` does for a single read
        let task = Task { @MainActor in
            for await items in updates { continuation.yield(self.sectioned(items)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

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
