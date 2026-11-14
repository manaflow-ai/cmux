public import CoreGraphics
public import Foundation
public import Observation
import CmuxNextDesign
import CmuxNextDesignTokens

/// Visual mode of a strip.
public enum TabStripStyle: Hashable, Sendable {
    /// Tab sizing: tabs shrink evenly between a max and min width, then scroll.
    case chrome
    /// Bonsplit-like: every tab has the same fixed width, overflow scrolls.
    case compact
}

/// Input of one tab strip. The App mirrors daemon state into `tabs` and
/// `selectedID`, and handles `TabStripIntent`s from `intentHandler`.
@Observable
public final class TabStripModel {
    /// Identifies this strip in cross-strip drags.
    public let stripID: UUID
    public var tabs: [TabItem] { didSet { followTabs() } }
    /// The strip holds one tab: a pane whose chat shares its row shows that row as no band over the chat,
    /// the transcript running up under the tab and tools (Leo, 2026-11-03: "isn't it kinda arbitrary anyway
    /// if you literally only have one tab there?"). Two or more tabs keep the row as before.
    public var holdsOneTab: Bool { tabs.count == 1 }
    /// Groups of this strip. Members reference them through `TabItem.groupID`.
    public var groups: [TabGroupItem]
    /// One tab, no group, and `tabs.hideLoneChatTab` on: a chat alone in its pane then draws no tab beside its tools
    /// in the tab row (#33132; `PaneTabRowSharing.tabRowTakesLoneTab`). Off by default (Leo 2026-11-03: "leave it as an optional toggle").
    public var hidesLoneTab: Bool { DesignSettings.shared.hideLoneChatTab && tabs.count == 1 && groups.isEmpty }
    /// The active tab. One outside `multiSelection` ends that selection.
    public var selectedID: TabID? { didSet { if selectedID != oldValue { followActive() } } }
    /// Cmd- and Shift-click's selection (`TabMultiSelection`); empty while only `selectedID` is selected.
    public var multiSelection = TabMultiSelection()
    /// Cmd- and Shift-click select several tabs. Off for a strip whose App takes no multi-tab
    /// actions (the screen bar).
    public var allowsMultiSelection: Bool
    public var style: TabStripStyle
    public var showsNewTabButton: Bool
    /// Full Width Tab mode: the strip shows only the selected tab, across its whole width
    /// (``TabLayoutEngine/layout(items:availableWidth:style:metrics:closingModeWidth:fullWidthTab:)``).
    public var showsSelectedFullWidth = false
    /// The strip's pane is zoomed: the pane shows ``PaneZoomIndicatorView`` at its top-right, whose
    /// click restores the layout (`TabStripIntent.toggleZoom`), and VoiceOver reads the selected tab
    /// as zoomed. The tabs draw nothing for it, so a zoom never changes the strip's width or moves a tab.
    public var zoomsSelected = false

    /// Receives every intent. Set by the App (or the demo).
    @ObservationIgnored public var intentHandler: ((TabStripIntent) -> Void)?
    /// Tabs taking another tab's place, keyed by the new tab (what a New Tab page turns into): the
    /// strip shows the new tab in that tab's cell, which leaves with no close, instead of growing
    /// one in while the other shrinks away (Leo 2026-10-13).
    @ObservationIgnored public var successors: [TabID: TabID] = [:]
    /// The close-selection rule's pick for this strip, set by the App to its window's state (who opened which
    /// tab; `TabCloseSelection` in CmuxNextBridge): the tab selected after `closed`, the selected tab, left
    /// `old`, with `surviving` left, `shown` not hidden and `groups` each grouped tab's group. Nil: the rule by
    /// position and group (no opener is known).
    @ObservationIgnored public var closeSuccessor: ((_ closed: TabID, _ old: [TabID], _ surviving: [TabID], _ shown: Set<TabID>,
                                                     _ groups: [TabID: String]) -> TabID?)?
    /// Tabs leaving this strip by a move to another pane, not a close (`TabMoves.depart` in the App):
    /// each leaves at once with no close, and the tabs left close up on the strip's move (Leo
    /// 2026-11-07: "you have a thing that you already dragged, and yet you're playing the closed tab
    /// animation. You should play no animation there").
    @ObservationIgnored public var departures: Set<TabID> = []

    public init(
        stripID: UUID = UUID(),
        tabs: [TabItem] = [],
        groups: [TabGroupItem] = [],
        selectedID: TabID? = nil,
        style: TabStripStyle = .chrome,
        showsNewTabButton: Bool = true,
        allowsMultiSelection: Bool = true
    ) {
        self.stripID = stripID
        self.tabs = tabs
        self.groups = groups
        self.selectedID = selectedID
        self.style = style
        self.showsNewTabButton = showsNewTabButton
        self.allowsMultiSelection = allowsMultiSelection
    }

    /// Display order: pinned tabs first, then unpinned tabs in `tabs` order
    /// with each group's members gathered at its first member. `groupID` is
    /// cleared on pinned tabs and on tabs whose group is unknown.
    public var orderedTabs: [TabItem] {
        TabGroupOrdering.normalized(tabs, groups: Set(groups.map(\.id)))
    }

    /// The places a sync hands over, new tab to old: a tab with no cell yet (`shown`) taking the
    /// place of one that has a cell and leaves in this sync (`next`). Stale entries go.
    func takeSuccessions(shown: Set<TabID>, next: Set<TabID>) -> [TabID: TabID] {
        let taken = successors.filter { !shown.contains($0.key) && next.contains($0.key) && shown.contains($0.value) && !next.contains($0.value) }
        // Kept while the new tab has no cell and the old one still has.
        successors = successors.filter { !shown.contains($0.key) && shown.contains($0.value) && !taken.keys.contains($0.key) }
        return taken
    }

    public func tab(_ id: TabID) -> TabItem? {
        tabs.first { $0.id == id }
    }

    public func group(_ id: TabGroupID) -> TabGroupItem? {
        groups.first { $0.id == id }
    }

    /// Members of `group` in display order.
    public func members(of group: TabGroupID) -> [TabItem] {
        orderedTabs.filter { $0.groupID == group }
    }

    public func send(_ intent: TabStripIntent) {
        intentHandler?(intent)
    }

    static func pinnedFirst(_ tabs: [TabItem]) -> [TabItem] {
        tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
    }

    /// The selection after `closed` left this strip: the close rule's pick when it was the selected tab
    /// (over the tabs a collapsed group does not hide), else the selection as it is.
    func selectionAfterClosing(_ closed: TabID) -> TabID? {
        let ordered = orderedTabs.map(\.id)
        guard selectedID == closed, ordered.contains(closed) else { return selectedID }
        let surviving = ordered.filter { $0 != closed }
        return successor(of: closed, old: ordered, surviving: surviving, shown: Set(visibleOrderedTabs.map(\.id)).intersection(surviving))
    }

    /// The tab selected after `closed`, the selected tab, left `old`: the App's rule state when it gave one
    /// (``closeSuccessor``), else the rule with no opener known.
    func successor(of closed: TabID, old: [TabID], surviving: [TabID], shown: Set<TabID>) -> TabID? {
        let groups = Dictionary(tabGroups.map { (TabID($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        if let closeSuccessor { return closeSuccessor(closed, old, surviving, shown, groups) }
        return CloseSelection<TabID>().successor(ofTab: closed, old: old, surviving: surviving, shown: shown, groups: groups)
    }

    /// The members of a collapsed group, which the strip does not show: a closed selected tab's successor
    /// skips them while a shown tab survives (close-focus.md).
    public var hiddenTabs: Set<String> {
        let collapsed = Set(groups.filter(\.isCollapsed).map(\.id))
        return collapsed.isEmpty ? [] : Set(tabs.filter { $0.groupID.map(collapsed.contains) ?? false }.map(\.id.rawValue))
    }

    /// Each grouped tab's group, by tab id (the close rule's group step reads it).
    public var tabGroups: [String: String] {
        Dictionary(tabs.compactMap { tab in tab.groupID.map { (tab.id.rawValue, $0.rawValue) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The tab to select as tab group `group` closes: nil when the selected tab is not one of its members
    /// (the selection stays), else the close rule's pick over the tabs outside the group.
    public func selectionAfterClosing(group: TabGroupID) -> TabID? {
        guard let selectedID, tab(selectedID)?.groupID == group else { return nil }
        let ordered = orderedTabs, surviving = ordered.filter { $0.groupID != group }.map(\.id)
        return successor(of: selectedID, old: ordered.map(\.id), surviving: surviving, shown: Set(surviving).subtracting(hiddenTabs.map { TabID($0) }))
    }
}
