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

    func configureColor(_ content: WorkspaceRowContent) {
        let next = content.rowColor.map { (color: $0, style: content.colorStyle) }
        guard next?.color != rowColor?.color || next?.style != rowColor?.style || content.railLook != railLook else { return }
        (rowColor, railLook) = (next, content.railLook)
        let bar = next?.style == .leftRail && railLook.drawsBar
        if bar, colorRail.superview == nil {
            colorRail.wantsLayer = true
            addSubview(colorRail, positioned: .below, relativeTo: nil)
        }
        colorRail.layer?.cornerRadius = railLook.rounded ? railLook.barWidth / 2 : 0
        colorRail.isHidden = !bar
        (needsDisplay, needsLayout) = (true, true)
    }

    /// Inside `updateLayer`'s theme scope, after the title's ink is set: tints a `leftRail` row's bar and title
    /// (``WorkspaceRailLook``) and returns the fill a `fill`-style row, or a washed `leftRail` row, paints for its
    /// state; nil for any other row (it keeps the gray steps).
    func colorFill() -> NSColor? {
        guard let rowColor else { return nil }
        let dim = isArchived ? SidebarStyle.archivedAlpha : 1
        let emphasized = isDropTarget || isSelected
        let hovered = isHovered && !isPlaceholderRow && DesignSettings.shared.showsHoverFills
        guard rowColor.style == .fill else {
            let look = railLook
            let ink = look.ink == .swatch ? rowColor.color.swatch : rowColor.color.railColor(emphasized: emphasized, muted: look.ink == .muted)
            colorRail.layer?.backgroundColor = ink.withAlphaComponent(dim).cgColor
            if look.titleTint > 0, let tinted = title.textColor.blended(withFraction: look.titleTint, of: rowColor.color.swatch) {
                title.textColor = tinted
            }
            guard look.wash > 0 else { return nil }
            // A washed row keeps its states: the wash steps up on hover and doubles when selected.
            let alpha = emphasized ? look.wash * 2 : isSecondarySelected || isOnScreen ? look.wash * 1.5
                : hovered ? look.wash * 1.3 : look.wash
            return rowColor.color.swatch.withAlphaComponent(alpha * dim)
        }
        let a = Self.colorFillAlpha
        let alpha = emphasized ? a.selected : isSecondarySelected || isOnScreen ? a.soft : hovered ? a.hover : a.rest
        return rowColor.color.swatch.withAlphaComponent(alpha * dim)
    }

    /// Lays the bar out (``WorkspaceRailLook``): down the row inside its inset, or a short pill on the title's line
    /// centered on `centerY` (the name line's center), `lead` from the fill's leading edge.
    func layoutColorRail(in bounds: NSRect, centerY: CGFloat) {
        guard !colorRail.isHidden else { return }
        // A started workspace's rail moves in with its content (`treeDepth`), clear of its parent's. The bar sits in the
        // row's leading inset, left of the one title edge, so a colored title starts where every other does (Lawrence
        // 2026-11-09, "red dot on left feels weird").
        let inset = Metrics.space1, indent = CGFloat(treeDepth) * SidebarStyle.treeIndent, look = railLook
        let full = max(0, bounds.height - 2 * inset)
        let height = look.length == .row ? full : min(full, (SidebarStyle.titleFont.capHeight + Metrics.space1).rounded())
        let y = look.length == .row ? bounds.minY + inset : (centerY - height / 2).rounded()
        colorRail.frame = NSRect(x: bounds.minX + indent + look.lead, y: y, width: look.barWidth, height: height)
    }
}
