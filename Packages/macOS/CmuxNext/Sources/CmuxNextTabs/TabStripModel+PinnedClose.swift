/// What the user's Cmd-W does to a tab.
public enum TabKeyboardClose: Hashable, Sendable {
    /// Close the tab, pinned or not, as Chrome's Cmd-W does (cmux-ad i8). The close then selects
    /// by the one close-selection rule (``TabStripModel/closeSuccessor``).
    case close
    /// Keep a tab that cannot close (Home's tab) and select this tab instead.
    case select(TabID)
    /// Do nothing and say nothing: a tab that cannot close (Home's tab) with nothing else to
    /// select. Cmd-W in the Home Chief pane is not an error (plans/cmux-next/home-chief-pane.md).
    case ignore
}

// The strip's commands on its tabs are cmux-window-rules' (`tabs::strip`, ops `tab_strip_*` of the app FFI's JSON
// channel): each sends the strip in display order (`orderedTabs`) with its collapsed groups and the tab it acts on.
// `TabStripCommandVectorTests` checks them against the vectors the Swift rules wrote before they moved.
extension TabStripModel {
    /// What Cmd-W does to `id`: it closes it, pinned or not, as Chrome's Cmd-W does (Lawrence
    /// 2026-11-08, cmux-ad i8: "make it consistent, match chrome's behavior"). Only a tab that
    /// cannot close (``TabItem/isClosable`` false: Home's tab, `pinned-dock-v1`) is kept: the next
    /// visible tab in strip order is selected (the previous one when it is last), else nothing.
    public func keyboardClose(_ id: TabID) -> TabKeyboardClose {
        // Every closable tab closes; only a kept one asks where the selection goes.
        guard tab(id)?.isClosable == false else { return .close }
        nonisolated struct Reply: Decodable { var action: String, tab: String? }
        guard let reply: Reply = TabRules.call("tab_strip_keyboard_close", stripRequest(id)) else { return .close }
        switch (reply.action, reply.tab) {
        case let ("select", tab?): return .select(TabID(tab))
        case ("ignore", _): return .ignore
        default: return .close
        }
    }
}

extension TabStripModel {
    // Chrome's close commands (`TabStripModel::GetTabsClosedByCommand`): Close Other Tabs and
    // Close Tabs to the Right (and cmux's Close Tabs to the Left) never close a pinned tab. Only
    // Close Tab, Cmd-W, the CLI or MCP naming the tab closes a pinned tab.
    // None of them lists a tab that cannot close (Home's tab, `pinned-dock-v1`).

    /// The tabs Close Other Tabs closes for `keep`, in strip order: every other unpinned tab.
    public func closedByCloseOthers(keeping keep: TabID) -> [TabID] {
        closedBy(keep)?.others.map { TabID($0) } ?? []
    }

    /// The tabs Close Tabs to the Right closes for `id`, in strip order: the unpinned tabs after it.
    public func closedByCloseToRight(of id: TabID) -> [TabID] {
        closedBy(id)?.right.map { TabID($0) } ?? []
    }

    /// The tabs Close Tabs to the Left closes for `id`, in strip order: the unpinned tabs before it.
    public func closedByCloseToLeft(of id: TabID) -> [TabID] {
        closedBy(id)?.left.map { TabID($0) } ?? []
    }

    /// The tab Close Other Tabs, Close Tabs to the Left or Close Tabs to the Right started from
    /// `actedOn` selects (cmux-ad i7): `actedOn`, the tab the person acted on, which stays. Nil (the
    /// selection does not change) when the selection is `actedOn` or one of `kept`, the tabs the
    /// gesture keeps on purpose (a menu opened on one of several selected tabs keeps them all).
    public func selectionKeeping(_ actedOn: TabID, kept: [TabID] = []) -> TabID? {
        nonisolated struct Request: Encodable { var id: String, selected: String?, kept: [String] }
        nonisolated struct Reply: Decodable { var tab: String? }
        let request = Request(id: actedOn.rawValue, selected: selectedID?.rawValue, kept: kept.map(\.rawValue))
        guard let reply: Reply = TabRules.call("tab_strip_selection_keeping", request) else { return actedOn }
        return reply.tab.map { TabID($0) }
    }

    private nonisolated struct ClosedBy: Decodable {
        var others, left, right: [String]
    }

    private func closedBy(_ id: TabID) -> ClosedBy? {
        TabRules.call("tab_strip_closed_by", stripRequest(id))
    }
}

extension TabStripModel {
    /// Where Move Tab Left (`offset` -1) or Move Tab Right (+1) takes `id`, as a display index;
    /// nil at the edge of its section. A pinned tab moves only among the pinned tabs and an
    /// unpinned one only among the rest, as in Chrome. A group's members stay together
    /// (`TabGroupOrdering.normalized`), so a tab outside a group steps past the whole group, and a
    /// member moves only among its group's members.
    public func moveIndex(of id: TabID, by offset: Int) -> Int? {
        nonisolated struct Reply: Decodable { var index: Int? }
        return (TabRules.call("tab_strip_move_index", stripRequest(id, offset: offset)) as Reply?)?.index
    }
}

extension TabStripModel {
    /// The tabs the strip shows, in strip order: every tab but the members
    /// of a collapsed group (Chrome's next and previous tab skip them too).
    public var visibleOrderedTabs: [TabItem] {
        let collapsed = Set(groups.filter(\.isCollapsed).map(\.id))
        return orderedTabs.filter { tab in tab.groupID.map { !collapsed.contains($0) } ?? true }
    }

    /// The visible tab `offset` steps from `id` in strip order, wrapping
    /// (Next / Previous Tab). From a hidden tab it counts from its place.
    public func adjacentVisibleTab(from id: TabID?, offset: Int) -> TabID? {
        nonisolated struct Reply: Decodable { var tab: String? }
        return (TabRules.call("tab_strip_adjacent", stripRequest(id, offset: offset)) as Reply?)?.tab.map { TabID($0) }
    }
}

/// One tab of a `tab_strip_*` request, in display order.
private nonisolated struct StripTab: Encodable {
    var id: String
    var pinned: Bool
    var closable: Bool
    var group: String?
}

private nonisolated struct StripRequest: Encodable {
    var tabs: [StripTab]
    var collapsed: [String]
    var id: String?
    var offset: Int
}

private extension TabStripModel {
    /// The strip as the rules read it: `orderedTabs` (no group on a pinned tab or one whose group is unknown) and
    /// the collapsed groups, with the tab a command acts on.
    func stripRequest(_ id: TabID?, offset: Int = 0) -> StripRequest {
        let tabs = orderedTabs.map { StripTab(id: $0.id.rawValue, pinned: $0.isPinned, closable: $0.isClosable, group: $0.groupID?.rawValue) }
        return StripRequest(tabs: tabs, collapsed: groups.filter(\.isCollapsed).map(\.id.rawValue).sorted(), id: id?.rawValue, offset: offset)
    }
}
