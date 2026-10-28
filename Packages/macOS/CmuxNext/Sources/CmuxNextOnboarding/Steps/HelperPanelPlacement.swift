import AppKit

/// Where the drag panel (`HelperDragPanel`) sits next to the window it
/// helps with, in AppKit screen coordinates: centered just under that
/// window, so it reads as part of it (user 2026-10-27: the panel floating on
/// its own at the bottom of the screen looked "decoupled"). With no room
/// under the window it goes just above it, and with no room there either it
/// sits inside the window's bottom edge. It never leaves the visible frame.
struct HelperPanelPlacement: Equatable {
    /// The space between the window's edge and the panel.
    var gap: CGFloat = 10

    /// The panel's origin for a panel of `size` docked to `anchor` on a
    /// screen whose visible frame is `visible`.
    func origin(panel size: NSSize, anchor: NSRect, visible: NSRect) -> NSPoint {
        let below = anchor.minY - gap - size.height
        let above = anchor.maxY + gap
        let y: CGFloat = if below >= visible.minY {
            below
        } else if above + size.height <= visible.maxY {
            above
        } else {
            anchor.minY + gap
        }
        let x = anchor.midX - size.width / 2
        let clampedX = min(max(x, visible.minX + gap), max(visible.minX + gap, visible.maxX - gap - size.width))
        let clampedY = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return NSPoint(x: clampedX.rounded(), y: clampedY.rounded())
    }
}
