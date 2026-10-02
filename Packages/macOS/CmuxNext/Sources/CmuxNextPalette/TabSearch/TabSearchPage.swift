import CmuxNextDesign
public import Foundation

/// What Search Tabs reads and does. The App implements it over its mirror
/// of every machine's daemon store, the location trail and the closed-items
/// log; `MockTabSearchSource` demos the page alone.
public protocol TabSearchSource: AnyObject {
    /// Every open tab (all kinds, panes, workspaces, windows, machines) and
    /// the recently closed tabs, as of now.
    func tabSearchEntries() -> [TabSearchEntry]
    /// Shows the tab: its window comes forward, its workspace, screen,
    /// column and tab are selected and its pane takes focus.
    func focusTab(id: String)
    /// Closes the open tab, as Close Tab does.
    func closeTab(id: String)
    /// Reopens a closed tab where it was.
    func reopenClosedTab(id: String)
    /// Removes a closed tab from the closed-items log.
    func forgetClosedTab(id: String)
}

/// The Search Tabs page (Cmd-Shift-A, action `tab.search`): every tab with
/// recently closed tabs below. Return focuses and reveals the row's tab or
/// reopens a closed one; Cmd-W closes the row's tab, or removes a closed
/// one from the list, and keeps the page open.
public enum TabSearchPage {
    public static let id = "tabSearch"

    /// `style` nil uses the Debug Settings prototype (`recent` in Release).
    public static func make(source: any TabSearchSource, style: TabSearchStyle? = nil,
                            query: String = "", now: @escaping @MainActor () -> Date = Date.init) -> PalettePageSpec {
        let style = style ?? PaletteTunables.tabSearchStyle.value
        let rows = TabSearchPlan.rows(source.tabSearchEntries(), style: style, now: now())
        let listed = TabSearchRowsProvider(id: "tabSearch.listed", showsItemsForEmptyQuery: true) { [weak source] in
            guard let source else { return [] }
            return TabSearchPlan.rows(source.tabSearchEntries(), style: style, now: now()).filter(\.isVisibleWhenQueryEmpty)
        }
        let older = TabSearchRowsProvider(id: "tabSearch.older", showsItemsForEmptyQuery: false) { [weak source] in
            guard let source else { return [] }
            return TabSearchPlan.rows(source.tabSearchEntries(), style: style, now: now()).filter { !$0.isVisibleWhenQueryEmpty }
        }
        listed.source = source
        older.source = source
        return PalettePageSpec(
            id: id, title: PaletteStrings.tabSearchTitle, placeholder: PaletteStrings.tabSearchPlaceholder,
            symbol: "magnifyingglass", providers: [listed, older], initialQuery: query, keepsSectionOrder: true,
            emptyQuerySelection: TabSearchPlan.emptyQuerySelection(rows.filter(\.isVisibleWhenQueryEmpty)))
    }

    /// The palette row of `row`, with its commands.
    static func item(_ row: TabSearchRow, source: any TabSearchSource) -> PaletteItem {
        let entry = row.entry
        let id = entry.id
        let primary: PaletteCommand
        let close: PaletteCommand
        if entry.isClosed {
            primary = PaletteCommand(id: "reopen", title: PaletteStrings.tabSearchReopen, symbol: "arrow.uturn.backward",
                                     effect: .perform { [weak source] in source?.reopenClosedTab(id: id) })
            close = PaletteCommand(id: "close", title: PaletteStrings.tabSearchForget, symbol: "minus.circle", isDestructive: true,
                                   effect: .performKeepingOpen { [weak source] in source?.forgetClosedTab(id: id) })
        } else {
            primary = PaletteCommand(id: "focus", title: PaletteStrings.switchToTab, symbol: "return",
                                     effect: .perform { [weak source] in source?.focusTab(id: id) })
            close = PaletteCommand(id: "close", title: PaletteStrings.closeTab, symbol: "xmark", isDestructive: true,
                                   effect: .performKeepingOpen { [weak source] in source?.closeTab(id: id) })
        }
        var item = PaletteItem(
            id: (entry.isClosed ? "closed:" : "tab:") + id, title: row.title, subtitle: row.subtitle, accessory: row.accessory,
            symbol: entry.rowSymbol,
            section: PaletteSection(id: row.section.id, title: row.section.title, order: row.section.order),
            keywords: row.keywords, isEnabled: entry.isAvailable, primary: primary, closeCommand: close, rankBias: row.rankBias)
        // Recency from the location trail ranks these rows; palette usage
        // counts would fight it.
        item.frecencyKey = nil
        return item
    }
}

/// A provider over Search Tabs rows, rebuilt on every load so Cmd-W and
/// keep-open commands see the source's current state.
final class TabSearchRowsProvider: PaletteProvider {
    let id: String
    let showsItemsForEmptyQuery: Bool
    weak var source: (any TabSearchSource)?
    private let rows: @MainActor () -> [TabSearchRow]

    init(id: String, showsItemsForEmptyQuery: Bool, rows: @escaping @MainActor () -> [TabSearchRow]) {
        self.id = id
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
        self.rows = rows
    }

    var immediateItems: [PaletteItem]? {
        guard let source else { return [] }
        return rows().map { TabSearchPage.item($0, source: source) }
    }

    func items() async -> [PaletteItem] { immediateItems ?? [] }
}
