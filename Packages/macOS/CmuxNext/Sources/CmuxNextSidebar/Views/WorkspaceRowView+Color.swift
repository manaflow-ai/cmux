import AppKit
import CmuxNextDesign

/// `workspaceColors.indicatorStyle` (#25653): a colored workspace's row as a bar down its leading
/// edge (`leftRail`) or filled with its color (`fill`), in place of the dot before its name. The
/// fill steps up for hover, multi-selection and selection, so a selected colored row still reads
/// as selected; light and dark both use the group color's own swatch.
extension WorkspaceRowView {
    /// The fill's opacity of the color swatch at rest, hovered, softly selected and selected.
    static let colorFillAlpha: (rest: CGFloat, hover: CGFloat, soft: CGFloat, selected: CGFloat) = (0.26, 0.34, 0.40, 0.52)
    static let colorRailWidth: CGFloat = 3

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
        needsDisplay = true
        needsLayout = true
    }

    /// The fill a `fill`-style row paints for its state; nil for any other row (it keeps the gray steps).
    func colorFill(selected: Bool, soft: Bool, hovered: Bool) -> NSColor? {
        guard let rowColor, rowColor.style == .fill else { return nil }
        let a = Self.colorFillAlpha
        let alpha = selected ? a.selected : soft ? a.soft : hovered && DesignSettings.shared.showsHoverFills ? a.hover : a.rest
        return rowColor.color.swatch.withAlphaComponent(alpha)
    }

    /// Inside the row's theme scope (`updateLayer`), so the swatch resolves for light or dark.
    func tintColorRail() {
        guard let rowColor, rowColor.style == .leftRail else { return }
        colorRail.layer?.backgroundColor = rowColor.color.swatch.cgColor
    }

    func layoutColorRail(in bounds: NSRect) {
        guard !colorRail.isHidden else { return }
        let inset = Metrics.space1
        colorRail.frame = NSRect(x: bounds.minX + inset, y: bounds.minY + inset,
                                 width: Self.colorRailWidth, height: max(0, bounds.height - 2 * inset))
    }
}
