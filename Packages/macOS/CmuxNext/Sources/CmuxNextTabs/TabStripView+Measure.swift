public import AppKit

// Pane chrome measurement (`debug.pane_chrome`, tests).
extension TabStripView {
    /// The first (leftmost) tab's pill in this view's coordinates (flipped,
    /// top-left origin), or nil with no tab.
    public var firstTabPillFrame: CGRect? {
        guard let cell = cells.values.filter({ $0.frame.width > 0.5 }).min(by: { $0.frame.minX < $1.frame.minX }) else { return nil }
        let pill = cell.pillFrameInCell
        let origin = tabsClip.convert(CGPoint(x: cell.frame.minX + pill.minX, y: cell.frame.minY + pill.minY), to: self)
        return CGRect(origin: origin, size: pill.size)
    }

    /// Every laid-out tab's [x, width] in strip content points, in order
    /// (members collapsed behind a group chip and the drop gap left out).
    public var tabSlots: [[Double]] {
        result.slots.filter { !$0.isCollapsed && $0.id != Self.placeholderID }.map { [Double($0.x), Double($0.width)] }
    }

    /// The width the tabs may fill.
    public var tabAvailableWidth: Double { Double(result.availableWidth) }
}
