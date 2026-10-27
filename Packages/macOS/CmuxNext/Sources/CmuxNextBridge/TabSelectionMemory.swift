import CmuxNextCompat
import CmuxNextDesignTokens
public import Observation

/// Client-local tab selection per pane (the daemon's `active_tab` is only a
/// shared default). When the selected tab disappears, the selection goes to
/// the tab that took its slot, else the new last tab.
///
/// Keyed (`ObservedMap`, perf-speed-of-light.md I2): reading pane X's
/// selection observes pane X only, and a selection in another pane re-runs
/// nothing that read this one. A read never writes an observed value;
/// `resolve` writes the selection only when it changes.
@MainActor @Observable
public final class TabSelectionMemory {
    private let selected = ObservedMap<String, String>()
    /// The order `resolve` last saw per pane (for the neighbor after a close); never observed.
    @ObservationIgnored private var lastOrder: [String: [String]] = [:]
    /// Bumped by every selection change in any pane: for a reader that follows
    /// all of this window's selections (one read, no walk of the panes).
    public private(set) var revision: UInt64 = 0

    public init() {}

    private func set(_ tab: String?, in pane: String) {
        guard selected[pane] != tab else { return }
        selected[pane] = tab
        revision &+= 1
    }

    public func select(_ tab: String, in pane: String) {
        set(tab, in: pane)
    }

    public func selection(in pane: String) -> String? { selected[pane] }

    /// The tab to show for `pane` given its current order. Remembers the
    /// order so a later removal can pick the neighbor
    /// (`FocusAfterClose.tab`: the next shown tab, else the previous one;
    /// a member of a collapsed group in `hidden` is skipped while a shown
    /// tab survives; a link tab goes back to its opener family first, from
    /// `openers`, read only when the selected tab closed).
    public func resolve(pane: String, tabs: [String], defaultIndex: Int, hidden: Set<String> = [],
                        openers: () -> [String: String] = { [:] }) -> String? {
        defer { lastOrder[pane] = tabs }
        guard !tabs.isEmpty else {
            set(nil, in: pane)
            return nil
        }
        if let current = selected[pane] {
            if tabs.contains(current) { return current }
            if let old = lastOrder[pane], old.contains(current) {
                let pick = FocusAfterClose.tab(selected: current, old: old, surviving: tabs,
                                               shown: Set(tabs).subtracting(hidden), opener: openers()) ?? tabs[0]
                set(pick, in: pane)
                return pick
            }
        }
        let pick = tabs[min(max(defaultIndex, 0), tabs.count - 1)]
        set(pick, in: pane)
        return pick
    }

    /// Drops panes that no longer exist.
    public func prune(livePanes: Set<String>) {
        for pane in selected.keys where !livePanes.contains(pane) { set(nil, in: pane) }
        selected.compact { livePanes.contains($0) }
        lastOrder = lastOrder.filter { livePanes.contains($0.key) }
    }
}
