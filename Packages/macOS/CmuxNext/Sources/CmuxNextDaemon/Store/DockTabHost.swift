import Foundation

/// Where a new tab asked for in a pane goes (`pinned-dock-v1`, u9415: "html page keeps opening
/// here we need to make it structurally impossible"). A pinned column that takes no tabs (the Home
/// dock) holds only the tab it started with, so a tab asked for there goes to the pane beside it:
/// the screen's focused pane outside every such column and outside the left chat dock, else the
/// one focused most recently, then layout order. The daemon applies the same rule to every tab it
/// makes (cmux-tui `right_pane_beside_pinned_dock`); the app applies it to the tabs it shows
/// before the daemon answers (a provisional tab) and to the tabs only it holds (app-only pages,
/// session-local browser tabs), so no path puts a tab into the dock.
///
/// ```swift
/// switch DockTabHost.resolve(pane, columns: screen.columns, order: screen.layout.paneIDs,
///                            active: screen.defaultPane, focusedAt: { store.pane($0)?.focusedAt ?? 0 }) {
/// case .takesTabs: open(in: pane)
/// case .beside(let host): open(in: host)
/// case .alone: openNewColumnRightOfDock()
/// }
/// ```
public enum DockTabHost: Equatable, Sendable {
    /// The pane takes tabs: the tab goes there.
    case takesTabs
    /// The pane is in a dock that takes no tabs; the tab goes to this pane beside it.
    case beside(PaneID)
    /// The pane is in a dock that takes no tabs and nothing is beside it: the tab goes to a new
    /// column right of the dock (the daemon makes one for a browser or page tab), never into it.
    case alone

    /// Whether `dock` keeps every tab but its own out (pinned, `allow_tabs` off).
    public static func takesNoTabs(_ dock: DockSnapshot?) -> Bool {
        dock.map { $0.isPinned && !$0.allowsTabs } ?? false
    }

    /// The host of a tab asked for in `pane` on a screen with `columns`.
    /// - Parameters:
    ///   - pane: The pane the request named.
    ///   - columns: The screen's viewport columns (empty for a plain split screen: every pane takes tabs).
    ///   - order: The screen's panes in layout order.
    ///   - active: The screen's focused pane.
    ///   - focusedAt: A pane's focus recency (higher is more recent).
    /// - Returns: Where the tab goes.
    public static func resolve(_ pane: PaneID, columns: [ColumnSnapshot], order: [PaneID], active: PaneID?,
                               focusedAt: (PaneID) -> UInt64) -> DockTabHost {
        guard let column = columns.first(where: { $0.layout.paneIDs.contains(pane) }), takesNoTabs(column.dock) else {
            return .takesTabs
        }
        let excluded = Set(columns.filter { column in
            takesNoTabs(column.dock) || column.dock.map { $0.role == .agentChat || $0.edge == .left } ?? false
        }.flatMap(\.layout.paneIDs))
        let candidates = order.filter { !excluded.contains($0) }
        if let active, candidates.contains(active) { return .beside(active) }
        // Stable: equal recency keeps the layout order.
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            let (l, r) = (focusedAt(lhs.element), focusedAt(rhs.element))
            return l != r ? l > r : lhs.offset < rhs.offset
        }
        return ranked.first.map { .beside($0.element) } ?? .alone
    }
}
