import CmuxNextCompat
import CmuxNextDesign
public import Observation

/// Client-local tab selection per pane (the daemon's `active_tab` is only a
/// shared default). The one place a pane's shown tab is decided: `resolve`
/// is total (plans/cmux-next/pane-active-tab-DESIGN.md): a pane with tabs
/// always resolves to one of its own tabs (I2), and to a shown one whenever
/// any is shown (I5), except a tab the user just selected inside a
/// collapsed group, which stays while the pane expands that group.
///
/// - The selected tab left: `FocusAfterClose.tab` (next shown, else
///   previous; opener family first).
/// - The selected tab was hidden by a collapse from anywhere (this strip,
///   another window, the CLI): the next shown tab, else the previous one.
/// - No usable selection: the daemon's default tab (by id, never an index
///   into another list), else the first shown tab.
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
    /// Panes whose selection was set by `select` and not yet resolved while shown:
    /// an explicit pick of a hidden tab holds (its group expands) instead of bouncing out.
    @ObservationIgnored private var explicit: Set<String> = []
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
        explicit.insert(pane)
    }

    public func selection(in pane: String) -> String? { selected[pane] }

    /// The tab to show for `pane` given its current order (see the type's
    /// rules). `defaultTab` is the daemon's active tab id; `hidden` the
    /// members of collapsed groups. nil only when `tabs` is empty.
    public func resolve(pane: String, tabs: [String], defaultTab: String?, hidden: Set<String> = [],
                        openers: () -> [String: String] = { [:] }) -> String? {
        defer { lastOrder[pane] = tabs }
        guard !tabs.isEmpty else {
            explicit.remove(pane)
            set(nil, in: pane)
            return nil
        }
        let isShown = { (tab: String) in !hidden.contains(tab) }
        let firstShown = tabs.first(where: isShown)
        func pick(_ tab: String) -> String {
            explicit.remove(pane)
            set(tab, in: pane)
            return tab
        }
        if let current = selected[pane] {
            if tabs.contains(current) {
                if isShown(current) {
                    explicit.remove(pane)
                    return current
                }
                // Hidden: an explicit pick holds (the pane expands its group); a collapse moves out.
                if firstShown == nil || explicit.contains(pane) { return current }
                return pick(FocusAfterClose.neighbor(of: current, in: tabs, preferNext: true, where: isShown) ?? firstShown ?? current)
            }
            if let old = lastOrder[pane], old.contains(current) {
                return pick(FocusAfterClose.tab(selected: current, old: old, surviving: tabs,
                                                shown: Set(tabs).subtracting(hidden), opener: openers()) ?? firstShown ?? tabs[0])
            }
        }
        if let defaultTab, tabs.contains(defaultTab), isShown(defaultTab) || firstShown == nil { return pick(defaultTab) }
        return pick(firstShown ?? tabs[0])
    }

    /// Drops panes that no longer exist.
    public func prune(livePanes: Set<String>) {
        for pane in selected.keys where !livePanes.contains(pane) { set(nil, in: pane) }
        selected.compact { livePanes.contains($0) }
        lastOrder = lastOrder.filter { livePanes.contains($0.key) }
        explicit = explicit.filter { livePanes.contains($0) }
    }
}
