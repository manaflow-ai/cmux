import CmuxNextCompat
import CmuxNextDesign
public import Observation

/// Client-local tab selection per pane (the daemon's `active_tab` is only a
/// shared default). When the selected tab disappears, the selection goes to
/// the tab before it, else the one after it (`FocusAfterClose.tab`). It also keeps the pane
/// this window last focused in each workspace (the daemon's `focused_at` is a
/// default the app never writes, focus.md 2), which a sidebar row's face reads.
///
/// Keyed (`ObservedMap`, perf-speed-of-light.md I2): reading pane X's
/// selection observes pane X only, and a selection in another pane re-runs
/// nothing that read this one. A read never writes an observed value;
/// `resolve` writes the selection only when it changes.
@MainActor @Observable
public final class TabSelectionMemory {
    private let selected = ObservedMap<String, String>()
    /// The pane last focused per workspace id: reading workspace X's observes X only.
    private let focused = ObservedMap<String, String>()
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

    /// Records `pane` as the one this window last focused in `workspace`. A focus that stays on
    /// the same pane (every key typed into it) writes nothing, so no sidebar row re-maps.
    public func focus(_ pane: String, in workspace: String) {
        guard focused[workspace] != pane else { return }
        focused[workspace] = pane
    }

    /// Records a settled focus: `pane` in `workspace`, nothing when either is nil (no shown workspace or pane).
    public func focus(_ pane: String?, in workspace: String?) {
        guard let pane, let workspace else { return }
        focus(pane, in: workspace)
    }

    /// Takes a saved window's last focused panes (`focusedPanes` per workspace, `pane` in the `shown`
    /// workspace), so the sidebar rows show each workspace's focused tab from the first frame after a relaunch.
    public func restoreFocus(_ focusedPanes: [String: String], shown: String?, pane: String?) {
        for (workspace, pane) in focusedPanes { focus(pane, in: workspace) }
        focus(pane, in: shown)
    }

    /// The pane this window last focused in `workspace`; nil before any focus there.
    public func focusedPane(in workspace: String) -> String? { focused[workspace] }

    /// The tab to show for `pane` given its current order. Remembers the
    /// order so a later removal can pick the neighbor
    /// (`FocusAfterClose.tab`: the shown tab before it, else the one after
    /// it; a member of a collapsed group in `hidden` is skipped while a shown
    /// tab survives).
    public func resolve(pane: String, tabs: [String], defaultIndex: Int, hidden: Set<String> = []) -> String? {
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
    public func prune(livePanes: Set<String>) {
        for pane in selected.keys where !livePanes.contains(pane) { set(nil, in: pane) }
        selected.compact { livePanes.contains($0) }
        lastOrder = lastOrder.filter { livePanes.contains($0.key) }
    }
}
