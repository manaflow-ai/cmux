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
    /// One element after each change to the tabs or the closed list, once
    /// both are current (`TabSearchLiveUpdates` re-reads the page).
    func changes() -> AsyncStream<Void>
}

/// The Search Tabs page (Cmd-Shift-A, action `tab.search`): every tab with
/// recently closed tabs below. Return focuses and reveals the row's tab or
/// reopens a closed one; Cmd-W closes the row's tab, or removes a closed
/// one from the list, and keeps the page open.
extension PalettePageSpec {
    public static let tabSearchID = "tabSearch"
    static let tabSearchCloseCommandID = "tabSearch.close"

    /// `style` nil uses the Debug Settings prototype (`recent` in Release).
    public static func tabSearch(source: any TabSearchSource, style: TabSearchStyle? = nil,
                            query: String = "", now: @escaping @MainActor () -> Date = Date.init) -> PalettePageSpec {
        let style = style ?? PaletteTunables.tabSearchStyle.value
        // One snapshot per load: the first provider takes it, the second
        // reuses it, so both sections come from the same moment.
        let snapshot = TabSearchSnapshot(source: source, style: style, now: now)
        let rows = snapshot.fresh()
        let listed = TabSearchRowsProvider(id: "tabSearch.listed", showsItemsForEmptyQuery: true, source: source) {
            snapshot.fresh().filter(\.isVisibleWhenQueryEmpty)
        }
        let older = TabSearchRowsProvider(id: "tabSearch.older", showsItemsForEmptyQuery: false, source: source) {
            snapshot.last.filter { !$0.isVisibleWhenQueryEmpty }
        }
        return PalettePageSpec(
            id: tabSearchID, title: PaletteStrings.tabSearchTitle, placeholder: PaletteStrings.tabSearchPlaceholder,
            symbol: "magnifyingglass", providers: [listed, older], initialQuery: query, ownsCloseKey: true, keepsSectionOrder: true,
            emptyQuerySelection: TabSearchPlan.emptyQuerySelection(rows.filter(\.isVisibleWhenQueryEmpty)))
    }

    /// The palette row of `row`, with its commands.
    static func tabSearchItem(_ row: TabSearchRow, source: any TabSearchSource) -> PaletteItem {
        let entry = row.entry
        let id = entry.id
        let primary: PaletteCommand
        let close: PaletteCommand
        if entry.isClosed {
            primary = PaletteCommand(id: "reopen", title: PaletteStrings.tabSearchReopen, symbol: "arrow.uturn.backward",
                                     effect: .perform { [weak source] in source?.reopenClosedTab(id: id) })
            close = PaletteCommand(id: tabSearchCloseCommandID, title: PaletteStrings.tabSearchForget, symbol: "minus.circle", isDestructive: true,
                                   effect: .performKeepingOpen { [weak source] in source?.forgetClosedTab(id: id) })
        } else {
            primary = PaletteCommand(id: "focus", title: PaletteStrings.switchToTab, symbol: "return",
                                     effect: .perform { [weak source] in source?.focusTab(id: id) })
            close = PaletteCommand(id: tabSearchCloseCommandID, title: PaletteStrings.closeTab, symbol: "xmark", isDestructive: true,
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
