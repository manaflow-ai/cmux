import AppKit
import CmuxNextDesign

/// The sidebar's trailing indicator column (Lawrence 2026-10-20: "line everything up with the
/// group header's down chevron"). One slot, `controlSize` wide, ends `horizontalInset` from a row's
/// right edge. The group header's chevron (and its at-rest spinner, a109) and every workspace
/// row's lone trailing glyph (the unread dot, the working spinner, a warning dot) center on its x,
/// at every density and sidebar width. Header and row layouts read this one place.
extension SidebarStyle {
    /// The column slot's side: a row control's (the chevron's) size.
    static var trailingSlotSide: CGFloat { controlSize }

    /// The x every trailing indicator centers on, in a row (or header) of `rowWidth`.
    static func trailingColumnCenterX(rowWidth: CGFloat) -> CGFloat {
        rowWidth - horizontalInset - trailingSlotSide / 2
    }

    /// A `side`-square frame centered on the column x and on `centerY`.
    static func trailingColumnFrame(rowWidth: CGFloat, centerY: CGFloat, side: CGFloat) -> CGRect {
        CGRect(x: trailingColumnCenterX(rowWidth: rowWidth) - side / 2, y: centerY - side / 2, width: side, height: side)
    }
}
