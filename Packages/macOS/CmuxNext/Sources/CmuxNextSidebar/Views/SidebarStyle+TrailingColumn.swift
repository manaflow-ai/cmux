import AppKit
import CmuxNextDesign

/// The sidebar's trailing indicator column (Lawrence 2026-10-20: "line everything up with the
/// group header's down chevron"). One slot, `controlSize` wide, ends `horizontalInset` from a row's
/// right edge. The group header's chevron (and its at-rest spinner, a109) and every workspace
/// row's trailing glyph (the unread dot, the working spinner, a warning dot) and every band item's
/// dot or status center on its x, at every density and sidebar width, whatever else the row shows
/// (Lawrence msg 11914: other controls sit left of the column). Header and row layouts read this one place.
extension SidebarStyle {
    /// The column slot's side: a row control's (the chevron's) size.
    static var trailingSlotSide: CGFloat { controlSize }

    /// The x every trailing indicator centers on, in a row (or header) of `rowWidth`: the width up to
    /// the row's fill end (a band item, whose fill is inset by `horizontalInset`, passes its width
    /// less that inset), so every row kind lands on one list x.
    static func trailingColumnCenterX(rowWidth: CGFloat) -> CGFloat {
        rowWidth - horizontalInset - trailingSlotSide / 2
    }

    /// The column slot's leading edge in a row of `rowWidth`: every other trailing control (a
    /// disclosure, a count, the keycap, the hover close and more) ends left of it.
    static func trailingColumnStart(rowWidth: CGFloat) -> CGFloat {
        trailingColumnCenterX(rowWidth: rowWidth) - trailingSlotSide / 2
    }

    /// A `side`-square frame centered on the column x and on `centerY`.
    static func trailingColumnFrame(rowWidth: CGFloat, centerY: CGFloat, side: CGFloat) -> CGRect {
        CGRect(x: trailingColumnCenterX(rowWidth: rowWidth) - side / 2, y: centerY - side / 2, width: side, height: side)
    }
}
