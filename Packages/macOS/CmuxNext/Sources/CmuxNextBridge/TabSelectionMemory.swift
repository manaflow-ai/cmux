import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextTabs
public import Observation

/// Client-local tab selection per pane (the daemon's `active_tab` is only a
/// shared default). When the selected tab disappears, the selection goes to
/// the one close-selection rule's pick (``closeRule``: a tab of the closed tab's opener family,
/// else the next tab, the previous only when it was the last). It also keeps the pane
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
    /// Each pane's grouped tabs to their group as of its last ``resolve``: a closed tab's group, which the close rule reads.
    @ObservationIgnored private var lastGroups: [String: [String: String]] = [:]
    /// Bumped by every selection change in any pane: for a reader that follows
    /// all of this window's selections (one read, no walk of the panes).
    public private(set) var revision: UInt64 = 0
    /// Each pane whose selection changed since ``takeChanges()`` last ran, with its selection now; never observed.
    @ObservationIgnored private var changes: [String: String?] = [:]
    /// Who opened which tab of this window's panes: the close-selection rule's state (``TabCloseSelection``).
    /// Every selection change here reports to it; `resolve` asks it for the tab after a close.
    @ObservationIgnored public let closeRule = TabCloseSelection()

    public init() {}

    private func set(_ tab: String?, in pane: String, standIn: String? = nil) {
        let old = selected[pane]
        guard old != tab else { return }
        selected[pane] = tab
        revision &+= 1
        changes.updateValue(tab, forKey: pane)
        if let tab { closeRule.selected(tab, after: old, in: pane, standIn: standIn) }
    }

    /// Each pane whose selection changed (set, replaced or dropped: nil) since the last call, with its selection
    /// now. For the one reader that keeps a copy of every selection of this window (its saved record,
    /// `WindowRecordSaver`): it applies these and reads no pane. ONE caller only: a second one would take changes
    /// that the first never sees. One entry per pane at most, so it never holds more than the panes this window
    /// selected a tab in.
    package func takeChanges() -> [String: String?] {
        guard !changes.isEmpty else { return [:] }
        var taken: [String: String?] = [:]
        swap(&taken, &changes)
        return taken
    }

    /// Selects `tab` in `pane`. `standIn`: the tab whose place `tab` took (a stand-in's daemon tab, what a
    /// New Tab page turned into): the two are one item to the close-selection rule.
    public func select(_ tab: String, in pane: String, standIn: String? = nil) {
        set(tab, in: pane, standIn: standIn)
    }

    /// Selects `tab` in `pane` for a jump that writes the selection itself, before any pane controller hears of
    /// it (tab search, a pinned row, a notification, a link to a tab, `tab.focus`). `byPerson`: a person's own
    /// action, not the CLI, the socket or a script. A person's jump is a gesture to the close-selection rule, as
    /// a click on the tab is, and the rule must hear of the gesture before the selection changes: a mark that
    /// comes after it is not read. Nothing when the pane selects `tab` already.
    public func jump(to tab: String, in pane: String, byPerson: Bool) {
        guard selected[pane] != tab else { return }
        if byPerson { closeRule.personSelects(tab, in: pane) }
        set(tab, in: pane)
    }

    /// Selects `tab`, which this window just made in `pane`, now that the pane lists it (`tabs`). `replaced`: the
    /// tab whose place it took (what a New Tab page turned into); else the selected tab when that is a creation's
    /// stand-in `tabs` no longer lists. The close-selection rule keeps the two as one item.
    public func selectMade(_ tab: String, in pane: String, inPlaceOf replaced: String?, tabs: [String]) {
        let standIn = replaced ?? selected[pane].flatMap { old in ProvisionalTab.isProvisional(old) && !tabs.contains(old) ? old : nil }
        set(tab, in: pane, standIn: standIn)
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
    /// (``TabCloseSelection/successor(of:old:tabs:hidden:)``, the one
    /// close-selection rule; a member of a collapsed group in `hidden` is
    /// skipped while a shown tab survives). `closing`: the tabs a pending close hides
    /// (`DaemonStore.closingTabIDs`); asked only when a tab with an opener relation is no longer listed.
    public func resolve(pane: String, tabs: [String], defaultIndex: Int, hidden: Set<String> = [], groups: [String: String] = [:],
                        replaced: [StripTabID: StripTabID] = [:], closing: () -> Set<String> = { [] }) -> String? {
        let earlierGroups = lastGroups[pane] ?? [:]
        lastGroups[pane] = groups.isEmpty ? nil : groups
        closeRule.adopt(replaced)
        // Before the pick: a tab whose pending close was committed since the last call leaves the rule's state.
        if !closeRule.isEmpty { closeRule.settle(pane, lists: tabs, before: lastOrder[pane] ?? [], closing: closing) }
        // After the pick: a tab the pane no longer lists (closed, or moved away) leaves it; one a pending close hides stays.
        defer { lastOrder[pane] = tabs; closeRule.settle(pane, lists: tabs, closing: closing) }
        guard !tabs.isEmpty else {
            set(nil, in: pane)
            return nil
        }
        if let current = selected[pane] {
            if tabs.contains(current) { return current }
            if let old = lastOrder[pane], old.contains(current) {
                let pick = closeRule.successor(of: current, old: old, tabs: tabs, hidden: hidden,
                                               groups: earlierGroups.merging(groups) { _, now in now }) ?? tabs[0]
                closeRule.closeSelects { set(pick, in: pane) } // the close's own move: the rule does not hear of it
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
        lastGroups = lastGroups.filter { livePanes.contains($0.key) }
        closeRule.prune(livePanes: livePanes)
    }
}
