import Foundation

/// The rows of one load of the page.
final class TabSearchSnapshot {
    private weak var source: (any TabSearchSource)?
    private let style: TabSearchStyle
    private let now: @MainActor () -> Date
    private(set) var last: [TabSearchRow] = []

    init(source: any TabSearchSource, style: TabSearchStyle, now: @escaping @MainActor () -> Date) {
        self.source = source
        self.style = style
        self.now = now
    }

    /// Reads the source again and keeps the rows for `last`.
    func fresh() -> [TabSearchRow] {
        last = source.map { TabSearchPlan.rows($0.tabSearchEntries(), style: style, now: now()) } ?? []
        return last
    }
}

/// A provider over Search Tabs rows, rebuilt on every load so Cmd-W and
/// keep-open commands see the source's current state.
final class TabSearchRowsProvider: PaletteProvider {
    let id: String
    let showsItemsForEmptyQuery: Bool
    private weak var source: (any TabSearchSource)?
    private let rows: @MainActor () -> [TabSearchRow]

    init(id: String, showsItemsForEmptyQuery: Bool, source: any TabSearchSource, rows: @escaping @MainActor () -> [TabSearchRow]) {
        self.id = id
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
        self.source = source
        self.rows = rows
    }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    var immediateItems: [PaletteItem]? {
        guard let source else { return [] }
        return rows().map { PalettePageSpec.tabSearchItem($0, source: source) }
    }

    func items() async -> [PaletteItem] { immediateItems ?? [] }
}
