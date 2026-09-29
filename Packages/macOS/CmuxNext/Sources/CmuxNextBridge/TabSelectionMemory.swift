/// Client-local tab selection per pane (the daemon's `active_tab` is only a
/// shared default). When the selected tab disappears, Chrome's rule applies:
/// the tab that took its slot, else the new last tab.
public struct TabSelectionMemory: Sendable, Equatable {
    private var selected: [String: String] = [:]
    private var lastOrder: [String: [String]] = [:]

    public init() {}

    public mutating func select(_ tab: String, in pane: String) {
        selected[pane] = tab
    }

    public func selection(in pane: String) -> String? { selected[pane] }

    /// The tab to show for `pane` given its current order. Remembers the
    /// order so a later removal can pick the neighbor.
    public mutating func resolve(pane: String, tabs: [String], defaultIndex: Int) -> String? {
        defer { lastOrder[pane] = tabs }
        guard !tabs.isEmpty else {
            selected[pane] = nil
            return nil
        }
        if let current = selected[pane] {
            if tabs.contains(current) { return current }
            if let old = lastOrder[pane], let index = old.firstIndex(of: current) {
                let survivors = old[index...].dropFirst().first { tabs.contains($0) }
                    ?? old[..<index].last { tabs.contains($0) }
                let pick = survivors ?? tabs[min(index, tabs.count - 1)]
                selected[pane] = pick
                return pick
            }
        }
        let pick = tabs[min(max(defaultIndex, 0), tabs.count - 1)]
        selected[pane] = pick
        return pick
    }

    /// Drops panes that no longer exist.
    public mutating func prune(livePanes: Set<String>) {
        selected = selected.filter { livePanes.contains($0.key) }
        lastOrder = lastOrder.filter { livePanes.contains($0.key) }
    }
}
