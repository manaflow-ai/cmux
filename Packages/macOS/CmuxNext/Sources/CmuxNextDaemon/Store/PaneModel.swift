import Foundation
public import Observation

@Observable @MainActor
public final class PaneModel: Identifiable {
    public let id: String
    public internal(set) var handle: PaneID
    /// Durable resource id (`pane_…`) on registry daemons.
    public internal(set) var resourceID: ResourceID?
    public internal(set) var name: String?
    /// Daemon default tab; the window keeps its own selection.
    public internal(set) var defaultTabIndex: Int
    public internal(set) var focusedAt: UInt64
    /// The tabs in order. A write while the store holds the list (``holdTabs()``) changes the record at once and
    /// publishes nothing: ``publishHeldTabs()`` publishes the net change one time.
    public internal(set) var tabs: [TabModel] {
        get {
            access(keyPath: \.tabs)
            return tabList
        }
        set { writeTabs { $0 = newValue } }
    }
    @ObservationIgnored private var tabList: [TabModel]
    /// The list as it was published when the store began holding it (``holdTabs()``); nil while not held.
    @ObservationIgnored private var tabsBeforeHold: [TabModel]?
    /// The stand-in tabs that the overlay's lift took out while the list is held, by surface: the restore of the same
    /// lift puts the same record back (``takeLiftedTab(_:)``).
    @ObservationIgnored private var liftedTabs: [SurfaceID: TabModel] = [:]
    /// The first tab, set only when it is another tab (at each write of ``tabs``; while the store holds the list, one
    /// time at the hold's end): an observer of the first tab (a window's Home, `WorkspaceModel.isWindowHome`) does not
    /// wake for a tab added after it in the pane.
    public private(set) var firstTab: TabModel?
    public internal(set) var tabGroups: [TabGroupModel]
    /// Group spans over `tabs`, recomputed only when tabs or groups change.
    public private(set) var groupSpans: [TabGroupSpan] = []

    init(_ s: PaneSnapshot) {
        id = Self.identity(s)
        handle = s.id
        resourceID = s.resourceID
        name = s.name
        defaultTabIndex = s.activeTab
        focusedAt = s.focusedAt
        tabList = s.tabs.map(TabModel.init)
        tabGroups = s.tabGroups.map(TabGroupModel.init)
        recomputeSpans()
        adoptUnread()
        noteFirstTab()
    }

    /// Each write of the tab list. Not held: one publication, then the list's own work (the unread count and the first
    /// tab; the caller computes the group spans). Held: the record changes and nothing else, and the hold's end does
    /// the rest one time.
    private func writeTabs(_ change: (inout [TabModel]) -> Void) {
        guard tabsBeforeHold == nil else { return change(&tabList) }
        withMutation(keyPath: \.tabs) { change(&tabList) }
        adoptUnread()
        noteFirstTab()
    }

    /// Holds the publication of ``tabs`` and the list's own work (the unread count, the first tab, the group spans)
    /// until ``publishHeldTabs()`` (``DaemonStore/withOverlayLifted(writer:snapshot:_:)``): a write still changes the
    /// record at once. Returns false when the list was held already.
    func holdTabs() -> Bool {
        guard tabsBeforeHold == nil else { return false }
        tabsBeforeHold = tabList
        return true
    }

    /// Ends the hold: publishes the list one time when it is not the same records in the same order as at the hold's
    /// start, then does the list's own work one time.
    func publishHeldTabs() {
        guard let before = tabsBeforeHold else { return }
        tabsBeforeHold = nil
        liftedTabs = [:]
        if !before.elementsEqual(tabList, by: ===) { withMutation(keyPath: \.tabs) {} }
        adoptUnread()
        noteFirstTab()
        recomputeSpans()
    }

    /// Takes the stand-in tab `surface` out for the overlay's lift. While the list is held the pane keeps the record
    /// for the restore of the same lift (``takeLiftedTab(_:)``).
    func liftTab(surface: SurfaceID) -> TabModel? {
        guard let tab = removeTab(surface: surface) else { return nil }
        if tabsBeforeHold != nil { liftedTabs[surface] = tab }
        return tab
    }

    /// The record that this hold's lift took out for `surface`, one time; nil when it took none.
    func takeLiftedTab(_ surface: SurfaceID) -> TabModel? { liftedTabs.removeValue(forKey: surface) }

    /// Keeps ``firstTab`` (a write only when the first tab is another one).
    private func noteFirstTab() {
        if tabs.first !== firstTab { firstTab = tabs.first }
    }

    /// Its tabs' unread count (``UnreadTally``), kept by ``recountUnread()``.
    @ObservationIgnored private(set) var unread = UnreadTally()
    /// The screen that counts this pane.
    @ObservationIgnored weak var unreadScreen: ScreenModel?

    /// The tabs changed: they report to this pane, which recounts.
    private func adoptUnread() {
        for tab in tabs where tab.unreadPane !== self { tab.unreadPane = self }
        recountUnread()
    }

    /// Counts its tabs again (a tab's unread mark or the tab list changed) and tells its screen when the count changed.
    func recountUnread() {
        var tally = UnreadTally()
        for tab in tabs { tally.add(tab.unreadMark) }
        guard tally != unread else { return }
        unread = tally
        unreadScreen?.recountUnread()
    }

    static func identity(_ s: PaneSnapshot) -> String {
        s.resourceID?.rawValue ?? "pane:\(s.id.rawValue)"
    }

    func update(_ s: PaneSnapshot) {
        if handle != s.id { handle = s.id }
        if resourceID != s.resourceID { resourceID = s.resourceID }
        if name != s.name { name = s.name }
        if defaultTabIndex != s.activeTab { defaultTabIndex = s.activeTab }
        if focusedAt != s.focusedAt { focusedAt = s.focusedAt }
        if let groups = reconcile(tabGroups, with: s.tabGroups, id: \.id, make: TabGroupModel.init, update: { $0.update($1) }) {
            tabGroups = groups
        }
        if let reordered = reconcile(tabs, with: s.tabs, id: TabModel.identity, make: TabModel.init, update: { $0.update($1) }) {
            tabs = reordered
        }
        recomputeSpans()
    }

    func insertTab(_ tab: TabModel, at index: Int) {
        writeTabs { $0.insert(tab, at: min(max(index, 0), $0.count)) }
        recomputeSpans()
    }

    @discardableResult
    func removeTab(surface: SurfaceID) -> TabModel? {
        guard let index = tabs.firstIndex(where: { $0.surface == surface }) else { return nil }
        var removed: TabModel?
        writeTabs { removed = $0.remove(at: index) }
        recomputeSpans()
        return removed
    }

    /// Moves the tab `surface` to `index` (clamped) inside this pane.
    func moveTab(surface: SurfaceID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.surface == surface }) else { return recomputeSpans() }
        let final = min(max(index, 0), tabs.count - 1)
        if final != from {
            var reordered = tabs
            reordered.insert(reordered.remove(at: from), at: final)
            tabs = reordered
        }
        recomputeSpans()
    }

    func recomputeSpans() {
        // Held: the hold's end computes the spans one time.
        guard tabsBeforeHold == nil else { return }
        var spans: [TabGroupSpan] = []
        var open: (group: TabGroupID, start: Int)?
        for (index, tab) in tabs.enumerated() {
            if let run = open, tab.tabGroup == run.group { continue }
            if let run = open { spans.append(TabGroupSpan(group: run.group, range: run.start..<index)) }
            open = tab.tabGroup.map { (group: $0, start: index) }
        }
        if let run = open { spans.append(TabGroupSpan(group: run.group, range: run.start..<tabs.count)) }
        if spans != groupSpans { groupSpans = spans }
    }
}
