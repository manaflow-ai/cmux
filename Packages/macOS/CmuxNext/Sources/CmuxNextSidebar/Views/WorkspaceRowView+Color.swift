import AppKit
import CmuxNextDesign

/// `workspaceColors.indicatorStyle` (#25653): a colored workspace's row as a short bar at its leading
/// edge (`leftRail`) or filled with its color (`fill`), in place of the dot before its name. The
/// fill steps up for hover, multi-selection and selection, so a selected colored row still reads
/// as selected; light and dark both use the group color's own swatch. The bar is a quiet mark on the
/// title's line (`GroupColor.railRGB(_:emphasized:)`), a step stronger on a selected row (Lawrence
/// 2026-11-20, "these colors look horrible by default": the full-strength swatch ran the row's whole
/// height). An archived row dims both.
extension WorkspaceRowView {
    /// The fill's opacity of the color swatch at rest, hovered, softly selected and selected.
    static let colorFillAlpha: (rest: CGFloat, hover: CGFloat, soft: CGFloat, selected: CGFloat) = (0.26, 0.34, 0.40, 0.52)
    static let colorRailWidth: CGFloat = 3
    /// The bar's inset from the row fill's leading edge: it hugs the fill's edge, inside the rounded corner, so the
    /// row's leading inset keeps the most room between the bar and the title.
    static let colorRailLead: CGFloat = 1.5

    func configureColor(_ content: WorkspaceRowContent) {
        let next = content.rowColor.map { (color: $0, style: content.colorStyle) }
        guard next?.color != rowColor?.color || next?.style != rowColor?.style else { return }
        rowColor = next
        if next?.style == .leftRail, colorRail.superview == nil {
            colorRail.wantsLayer = true
            colorRail.layer?.cornerRadius = Self.colorRailWidth / 2
            addSubview(colorRail, positioned: .below, relativeTo: nil)
        }
        colorRail.isHidden = next?.style != .leftRail
        (needsDisplay, needsLayout) = (true, true)
    }

    /// Inside `updateLayer`'s theme scope: tints a `leftRail` row's bar and returns the fill a
    /// `fill`-style row paints for its state; nil for any other row (it keeps the gray steps).
    func colorFill() -> NSColor? {
        guard let rowColor else { return nil }
        let dim = isArchived ? SidebarStyle.archivedAlpha : 1
        guard rowColor.style == .fill else {
            let emphasized = isDropTarget || isSelected
            colorRail.layer?.backgroundColor = rowColor.color.railColor(emphasized: emphasized).withAlphaComponent(dim).cgColor
            return nil
        }
        let a = Self.colorFillAlpha, hovered = isHovered && !isPlaceholderRow && DesignSettings.shared.showsHoverFills
        let alpha = isDropTarget || isSelected ? a.selected : isSecondarySelected || isOnScreen ? a.soft : hovered ? a.hover : a.rest
        return rowColor.color.swatch.withAlphaComponent(alpha * dim)
    }

    /// Lays the bar out as a short pill on the title's line: as tall as the title's text, centered on `centerY` (the
    /// name line's center), clipped to the row's inset.
    func layoutColorRail(in bounds: NSRect, centerY: CGFloat) {
        guard !colorRail.isHidden else { return }
        // A started workspace's rail moves in with its content (`treeDepth`), clear of its parent's. The bar sits in the
        // row's leading inset, left of the one title edge, so a colored title starts where every other does (Lawrence
        // 2026-11-09, "red dot on left feels weird").
        let inset = Metrics.space1, indent = CGFloat(treeDepth) * SidebarStyle.treeIndent
        let font = SidebarStyle.titleFont
        let height = min(max(0, bounds.height - 2 * inset), (font.capHeight + Metrics.space1).rounded())
        colorRail.frame = NSRect(x: bounds.minX + indent + Self.colorRailLead, y: (centerY - height / 2).rounded(),
                                 width: Self.colorRailWidth, height: height)
    }
}
