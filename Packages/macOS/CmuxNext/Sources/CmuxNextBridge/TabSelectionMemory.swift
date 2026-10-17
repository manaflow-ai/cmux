import CmuxNextDesign

/// Client-local tab selection per pane (the daemon's `active_tab` is only a
/// shared default). When the selected tab disappears, the selection goes to
/// the tab that took its slot, else the new last tab.
public struct TabSelectionMemory: Sendable, Equatable {
    private var selected: [String: String] = [:]
    private var lastOrder: [String: [String]] = [:]
    /// Moves on every change of a pane's selected tab, so a reader can tell
    /// that the selection is the one it read before without comparing it.
    public private(set) var revision: UInt64 = 0

    public init() {}

    public mutating func select(_ tab: String, in pane: String) {
        set(tab, in: pane)
    }

    private mutating func set(_ tab: String?, in pane: String) {
        guard selected[pane] != tab else { return }
        selected[pane] = tab
        revision &+= 1
    }

    public func selection(in pane: String) -> String? { selected[pane] }

    /// The tab to show for `pane` given its current order. Remembers the
    /// order so a later removal can pick the neighbor
    /// (`FocusAfterClose.tab`: the next shown tab, else the previous one;
    /// a member of a collapsed group in `hidden` is skipped while a shown
    /// tab survives).
    public mutating func resolve(pane: String, tabs: [String], defaultIndex: Int, hidden: Set<String> = []) -> String? {
        defer { lastOrder[pane] = tabs }
        guard !tabs.isEmpty else {
            set(nil, in: pane)
            return nil
        }
        if let current = selected[pane] {
            if tabs.contains(current) { return current }
            if let old = lastOrder[pane], old.contains(current) {
                let pick = FocusAfterClose.tab(selected: current, old: old, surviving: tabs,
                                               shown: Set(tabs).subtracting(hidden)) ?? tabs[0]
                set(pick, in: pane)
                return pick
            }
        }
        let pick = tabs[min(max(defaultIndex, 0), tabs.count - 1)]
        set(pick, in: pane)
        return pick
    }

    /// Drops panes that no longer exist.
    public mutating func prune(livePanes: Set<String>) {
        let kept = selected.filter { livePanes.contains($0.key) }
        if kept.count != selected.count { selected = kept; revision &+= 1 }
        lastOrder = lastOrder.filter { livePanes.contains($0.key) }
    }
}
