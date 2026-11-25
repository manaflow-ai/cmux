import CoreGraphics
import Foundation

/// Where a tab sits among its screen's splits on the Mac, for its grid card: each shown pane's
/// frame as the Mac draws it (`Screen.shownFrames`, a 16:10 window) scaled into a unit square,
/// and the pane holding the tab. The phone shows one tab per page, so the card is the only
/// place the Mac's split layout can be seen at a glance.
public struct TabSplitMap: Hashable, Sendable {
    public struct Cell: Hashable, Sendable {
        public var pane: Int
        /// In 0...1 on both axes, in the Mac window's own proportions (`aspect`).
        public var rect: CGRect
    }

    /// The shown panes, in the Mac's tree order.
    public var cells: [Cell]
    /// The pane holding the tab.
    public var pane: Int
    /// The Mac window's width over its height.
    public var aspect: CGFloat
}

extension WorkspaceLayout {
    /// The split map of `tabID`'s screen; nil when its pane is not listed, the screen shows one
    /// pane, or its pane is zoomed (the Mac then shows that pane alone).
    public func splitMap(ofTab tabID: String) -> TabSplitMap? {
        guard let pane = pane(holding: tabID), let screen = screen(of: pane.id), !pane.isZoomed else { return nil }
        let frames = screen.shownFrames.filter { $0.value.width > 0 && $0.value.height > 0 }
        guard frames.count > 1, frames[pane.id] != nil else { return nil }
        let window = Screen.window
        let order = screen.panes.map(\.id)
        let cells = frames
            .sorted { (order.firstIndex(of: $0.key) ?? .max, $0.key) < (order.firstIndex(of: $1.key) ?? .max, $1.key) }
            .map { id, rect in
                TabSplitMap.Cell(pane: id, rect: CGRect(x: rect.minX / window.width, y: rect.minY / window.height,
                                                        width: rect.width / window.width, height: rect.height / window.height))
            }
        return TabSplitMap(cells: cells, pane: pane.id, aspect: window.width / window.height)
    }
}
