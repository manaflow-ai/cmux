import AppKit
import CmuxNextDesign

// `appearance.cornerFlush` flush-goo in the sidebar (``CornerFlush/sidebarRowFlows``): the selected row runs into the content card as the selected tab does.
// The window's chrome (`CornerFlushChrome`) cuts the row's shape, out to the card with its fillets, out of the frame's
// shade, and tells the list whether it did; the row then paints the content's fill, square on the card's side. Leo,
// 2026-11-18: "the "gooey" is each tab looking like it's morphing into the visible pane. the two tone thing."
extension SidebarListView: SidebarSelectionCorner {
    /// The selected row's frame in the window while it shows whole in the viewport and draws a rounded fill; nil
    /// otherwise, and always nil unless the sidebar row flows (goo on a block tab shape). O(1).
    var selectedRowFrameInWindow: CGRect? {
        guard CornerFlush.sidebarRowFlows, window != nil, let key = selectedRowKey, let row = rowViews[key],
              row.isSelected, !row.isHidden, row.fillCornerRadius > 0 else { return nil }
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        guard visible.insetBy(dx: -0.5, dy: -0.5).contains(row.frame) else { return nil }
        return convert(row.frame, to: nil)
    }

    func setSelectionRunsIntoCard(_ runs: Bool) {
        guard let key = selectedRowKey, let row = rowViews[key] else { return }
        let shown = runs && row.isSelected
        if row.runsIntoCard != shown { row.runsIntoCard = shown }
    }

    /// Tells the window's chrome where the selected row is now, when that changed: after an apply, a selection
    /// change and a scroll. O(1), and nothing when the frame is unchanged (every scroll tick asks).
    func reportGooeySelection() {
        let frame = selectedRowFrameInWindow
        guard frame != reportedGooeyRow || (frame != nil && !reportedGooeyLanded) else { return }
        reportedGooeyRow = frame
        reportedGooeyLanded = CornerFlushChrome.sidebarDidChange(self)
    }
}
