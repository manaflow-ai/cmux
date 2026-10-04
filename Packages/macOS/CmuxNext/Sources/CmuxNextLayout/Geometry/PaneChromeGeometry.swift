public import CoreGraphics

/// Pane padding composed with the rest of the layout. A pane's frame (its
/// cell) is what split and column geometry compute; its tab strip and
/// content sit in the cell inset by `panePadding`. The border and rounded
/// corners trace only the content area below the header (tab strip, browser
/// toolbar) when the hosted view reports one (`PaneContentChrome`).
extension LayoutStyle {
    /// Gap the column strip leaves between and around columns. Each pane
    /// already brings `panePadding` on every side, so the strip adds only
    /// what the padding does not cover: the visible space between two
    /// columns' panes is `max(columnGap, 2 * panePadding)`, never both.
    public nonisolated var stripGap: CGFloat {
        max(0, columnGap - panePadding * 2)
    }

    /// Width of a split divider's drag area: at least the visible space
    /// between the two padded panes, so the whole gap takes the drag.
    public nonisolated var effectiveDividerHitThickness: CGFloat {
        max(dividerHitThickness, panePadding * 2 + dividerThickness)
    }

    /// Width of a column edge's drag area centered on the column gap.
    public nonisolated var columnEdgeHitThickness: CGFloat {
        max(stripGap + panePadding * 2, dividerHitThickness)
    }

    /// Split dividers draw their line at rest only while panes have no
    /// border and the separation allows one (not `cards` or `none`).
    public nonisolated var showsDividerLine: Bool {
        drawsLines && !showsPaneBorder && paneSeparation != .cards && paneSeparation != .none
    }

    /// Dividers and column edges show a line on hover and while dragged,
    /// except under `layout.paneSeparation` none (the cursor is the cue).
    public nonisolated var showsDividerFeedback: Bool { paneSeparation.drawsDividerFeedback }

    /// Whether panes differ from plain edge-to-edge rectangles.
    public nonisolated var hasPaneChrome: Bool {
        panePadding > 0 || paneCornerRadius > 0 || showsPaneBorder
    }
}

/// Pure pane chrome geometry.
public nonisolated enum PaneChromeGeometry {
    /// The rounded content rect of a pane whose cell is `cell`. A cell
    /// smaller than twice the padding collapses to its center line.
    public static func contentRect(forCell cell: CGRect, style: LayoutStyle) -> CGRect {
        let dx = min(style.panePadding, cell.width / 2)
        let dy = min(style.panePadding, cell.height / 2)
        return cell.insetBy(dx: dx, dy: dy)
    }

    /// The rounded content area of a padded pane rect (`contentRect(forCell:)`)
    /// whose hosted view has a `headerHeight`-point header (tab strip,
    /// browser toolbar) on top: the border, ring and rounding leave the
    /// header out. Flipped coordinates (y grows down).
    public static func roundedRect(inPadded padded: CGRect, headerHeight: CGFloat, footerHeight: CGFloat = 0) -> CGRect {
        let top = min(max(0, headerHeight), padded.height)
        return CGRect(x: padded.minX, y: padded.minY + top, width: padded.width, height: padded.height - top)
    }

    /// Corner radius that fits `rect` (at most half its shorter side).
    public static func cornerRadius(for rect: CGRect, style: LayoutStyle) -> CGFloat {
        max(0, min(style.paneCornerRadius, min(rect.width, rect.height) / 2))
    }

    /// The pane border's line width: one device pixel.
    public static func hairlineWidth(scale: CGFloat) -> CGFloat {
        scale > 0 ? 1 / scale : 1
    }
}

extension DropTarget {
    /// A drop onto a pane (split zone or center), not a column gap.
    public nonisolated var isPaneZone: Bool {
        if case .pane = self { return true }
        return false
    }
}
