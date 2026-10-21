import CmuxNextLayout
import CmuxNextSettings

/// Where a web link opened from an agent chat lands (`links.openTarget`, ``ChatLinkTarget``): a
/// link in a reply, a pull request chip, the hover card's Open. Leo 2026-10-21: "WHY DID THIS NOT
/// OPEN TO THE SIDE?" (the link opened as a tab over the chat) and "if the left side has a tab, any
/// link opened also goes on the left instead of opening a new split. By default, things going to
/// the rightmost split is the thing to try."
///
/// - ``ChatLinkTarget/rightmost`` (default): a tab in the rightmost split of the chat's screen. When
///   that is the chat itself, a new split on the chat's right. A pane left of the chat never gets
///   the link, even one that shows a browser.
/// - ``ChatLinkTarget/newSplit``: always a new split on the chat's right.
/// - ``ChatLinkTarget/sameTab``: nil, so the rules for any page apply (``LinkOpener``).
///
/// Command-click keeps its meaning: the tab opens in the same target, in the background.
/// `Pane` is the caller's pane identity (`LayoutPaneID` in the app), so the rule runs without a
/// window or a daemon.
enum ChatLinkPlacement {
    /// Where a link opened from the chat in pane `chat` goes, or nil for ``ChatLinkTarget/sameTab``.
    /// `columns` are the chat's screen's columns left to right, each given by the panes along its
    /// right edge, top to bottom (``rightEdge(of:)``); `chatColumn` is the index of the column that
    /// holds the chat; `takesTabs` tells which panes take new tabs; `recency` lists panes newest first.
    static func target<Pane: Equatable>(_ setting: ChatLinkTarget, chat: Pane, columns: [[Pane]], chatColumn: Int?,
                                        takesTabs: (Pane) -> Bool, recency: [Pane]) -> LinkOpenPlacement<Pane>.Target? {
        switch setting {
        case .sameTab:
            return nil
        case .newSplit:
            return .splitRight(of: chat)
        case .rightmost:
            let pane = rightmost(from: chat, columns: columns, chatColumn: chatColumn, takesTabs: takesTabs, recency: recency)
            return pane.map { .pane($0) } ?? .splitRight(of: chat)
        }
    }

    /// The rightmost split right of or beside the chat that takes tabs and is not the chat: in the
    /// last column that has one, on that column's right edge, its most recently focused such pane,
    /// else its top one. Columns left of the chat's column are never searched. Nil when no such pane
    /// exists (the chat is the rightmost split), and when the chat's column is unknown.
    static func rightmost<Pane: Equatable>(from chat: Pane, columns: [[Pane]], chatColumn: Int?,
                                           takesTabs: (Pane) -> Bool, recency: [Pane]) -> Pane? {
        guard let chatColumn, columns.indices.contains(chatColumn) else { return nil }
        for column in columns[chatColumn...].reversed() {
            let candidates = column.filter { $0 != chat && takesTabs($0) }
            if let pane = recency.first(where: candidates.contains) ?? candidates.first { return pane }
        }
        return nil
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

    /// `columns` as ``target(_:chat:columns:chatColumn:takesTabs:recency:)`` reads them: each column's
    /// right edge (each row's, top to bottom, for a column with rows), and the index of the column
    /// holding `chat`. Top and bottom docks are bands across the screen, not columns beside the chat:
    /// they are left out.
    static func columns(_ columns: [LayoutColumn], chat: PaneID) -> (edges: [[PaneID]], chatColumn: Int?) {
        let beside = columns.filter { $0.dock?.edge.isBand != true }
        return (beside.map { $0.trees.flatMap(rightEdge(of:)) }, beside.firstIndex { $0.root.contains(chat) })
    }
}
