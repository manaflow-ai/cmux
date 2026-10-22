import CmuxNextLayout
import CmuxNextSettings

/// Where a web link opened from an agent chat lands (a link in a reply, a pull request chip, the
/// hover card's Open), by `layout.linkPlacement` (``LinkPlacement``). Leo 2026-10-21: "WHY DID THIS
/// NOT OPEN TO THE SIDE?" (the link opened as a tab over the chat), "if the left side has a tab, any
/// link opened also goes on the left instead of opening a new split", and "open on right by default".
///
/// - ``LinkPlacement/splitRight`` (default) and ``LinkPlacement/newColumn``: on the right. A pane
///   right of the chat gets a tab: the one the person focused last, else the rightmost. With no
///   pane there, a new split (or column) on the chat's right. A pane left of the chat never gets
///   it, and neither does a pane that shows an agent chat (the caller's `takesTabs` says no).
/// - ``LinkPlacement/samePane``: "in the agent pane": a tab in the chat's own pane, never main pane
///   layout's dock or column. In the chat dock, which holds only chats, nil: the rules for any page.
/// - A zoomed chat fills the screen and the panes beside it are hidden, so the link never goes to
///   one of them: on the right it opens a new split (or column), which ends the zoom.
///
/// Command-click keeps its meaning: the tab opens in the same target, in the background. Tabs can
/// still be dragged anywhere afterwards. `Pane` is the caller's pane identity (`LayoutPaneID` in the
/// app), so the rule runs without a window or a daemon.
nonisolated enum ChatLinkPlacement {
    /// Where a link from the chat in pane `chat` goes, or nil for ``LinkPlacement/samePane`` in the
    /// chat dock (`inChatDock`). `zoomed`: the chat's pane is zoomed. `right` lists the panes right of the chat, one group per column left to right (the chat's own
    /// column first, with only its panes right of the chat), each group's panes on the column's right
    /// edge first, top to bottom (``rightSide(of:in:)``). `takesTabs` tells which panes may get the
    /// link; `recency` lists panes newest first.
    static func target<Pane: Equatable>(_ setting: LinkPlacement, chat: Pane, right: [[Pane]],
                                        zoomed: Bool = false, inChatDock: Bool = false,
                                        takesTabs: (Pane) -> Bool, recency: [Pane]) -> LinkOpenPlacement<Pane>.Target? {
        switch setting {
        case .samePane:
            return inChatDock ? nil : .pane(chat)
        case .splitRight, .newColumn:
            if !zoomed, let pane = pane(from: chat, right: right, takesTabs: takesTabs, recency: recency) { return .pane(pane) }
            return setting == .newColumn ? .newColumn(rightOf: chat) : .splitRight(of: chat)
        }
    }

    /// The pane right of the chat that gets the link: of those that take tabs and are not the chat,
    /// the most recently focused, else the rightmost column's first (its right edge, top first).
    /// Nil when there is none.
    static func pane<Pane: Equatable>(from chat: Pane, right: [[Pane]], takesTabs: (Pane) -> Bool, recency: [Pane]) -> Pane? {
        let groups = right.map { $0.filter { $0 != chat && takesTabs($0) } }
        let candidates = groups.flatMap { $0 }
        return recency.first(where: candidates.contains) ?? groups.last(where: { !$0.isEmpty })?.first
    }

    /// The panes along `node`'s right edge, top to bottom: a side-by-side split's right side, both
    /// sides of a stacked one.
    static func rightEdge(of node: SplitNode) -> [PaneID] {
        switch node {
        case let .leaf(pane): [pane]
        case let .split(_, .horizontal, _, _, right): rightEdge(of: right)
        case let .split(_, .vertical, _, top, bottom): rightEdge(of: top) + rightEdge(of: bottom)
        }
    }

    /// The panes of `node` right of `pane`: the right side of every side-by-side split whose left
    /// side holds `pane`, in visual order. Empty when `node` does not hold `pane`.
    static func panes(rightOf pane: PaneID, in node: SplitNode) -> [PaneID] {
        switch node {
        case .leaf:
            return []
        case let .split(_, axis, _, a, b):
            if a.contains(pane) { return panes(rightOf: pane, in: a) + (axis == .horizontal ? b.panes : []) }
            return b.contains(pane) ? panes(rightOf: pane, in: b) : []
        }
    }

    /// `right` as ``target(_:chat:right:zoomed:inChatDock:takesTabs:recency:)`` reads it, from the chat's screen's
    /// `columns` in the order the person sees them (`ScreenLayout.visualColumns`). Top and bottom
    /// docks are bands across the screen, not beside the chat: they are left out. Empty when no
    /// column holds `chat`.
    static func rightSide(of chat: PaneID, in columns: [LayoutColumn]) -> [[PaneID]] {
        let beside = columns.filter { $0.dock?.edge.isBand != true }
        guard let index = beside.firstIndex(where: { $0.root.contains(chat) }) else { return [] }
        func edgeFirst(_ panes: [PaneID], _ column: LayoutColumn) -> [PaneID] {
            let edge = column.trees.flatMap(rightEdge(of:)).filter(panes.contains)
            return edge + panes.filter { !edge.contains($0) }
        }
        let own = beside[index].tree(containing: chat).map { panes(rightOf: chat, in: $0) } ?? []
        return [edgeFirst(own, beside[index])] + beside[(index + 1)...].map { edgeFirst($0.trees.flatMap(\.panes), $0) }
    }
}
