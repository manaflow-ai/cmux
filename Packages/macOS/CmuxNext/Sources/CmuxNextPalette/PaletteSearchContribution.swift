/// A page of the App's whose rows join Search (scope `search`,
/// plans/cmux-next/sidebar-search.md): the page's providers are asked once per
/// open, like every provider, and the palette's ranker searches their rows with
/// the rest. A page that answers its own queries (`PalettePageSpec.queryResults`)
/// is asked for each typed query instead (`PaletteContributedAnswers`). A row with
/// no section of its own shows under ``title``.
///
/// ```swift
/// sources.searchContributions.append(PaletteSearchContribution(id: "history", title: "History", order: 40) {
///     HistoryPalettePages.search(services)
/// })
/// ```
public struct PaletteSearchContribution {
    /// Stable id; it prefixes the contributed providers' ids so two pages never share one.
    public var id: String
    /// The section title for the page's unsectioned rows ("History", "Agent Chats").
    public var title: String
    /// The section's order among Search's sections when they keep their order (empty query).
    public var order: Int
    /// Whether the rows are chats or agent sessions: they also make up the Chats & agents scope.
    public var searchesChats: Bool
    /// Makes the page each time Search opens; nil when it has nothing now.
    public var page: @MainActor () -> PalettePageSpec?

    /// - Parameters:
    ///   - id: Stable id of the contribution.
    ///   - title: Section title for rows that carry none.
    ///   - order: Section order.
    ///   - searchesChats: True for chats and agent sessions (the Chats & agents scope lists them too).
    ///   - page: Makes the page whose providers (or query answers) join Search.
    public init(id: String, title: String, order: Int, searchesChats: Bool = false,
                page: @escaping @MainActor () -> PalettePageSpec?) {
        self.id = id
        self.title = title
        self.order = order
        self.searchesChats = searchesChats
        self.page = page
    }
}
