public import CoreGraphics

/// Which row the pointer hovers (Leo 2026-10-19). A row with hover controls
/// (a workspace or a tab row) takes the hover only inside its pill: its frame
/// inset by `inset` top and bottom, minus corners rounded by `cornerRadius`.
/// The gap between rows, a pill's corners and the margin beside it never hand
/// the hover to a new row, so a pointer leaving a row up and to the left does
/// not light the row above and put its "..." and close buttons in the way.
/// The row hovered now keeps the hover across the gap to its neighbors' pills,
/// so a sweep down or up the list never drops it between rows (#20315).
/// Other rows (headers, empty sections, blocks) hover on their whole tile.
extension SidebarLayout {
    /// Main actor: `frame` is the list view's own `frame(for:)`.
    @MainActor func hoverRow(
        at point: CGPoint, current: SidebarRowKey?, frame: (SidebarRow) -> CGRect,
        cornerRadius: CGFloat, inset: CGFloat
    ) -> SidebarRow? {
        if let row = row(at: point.y) {
            guard row.key.hasHoverPill else { return row }
            if Self.pill(frame(row), inset: inset, cornerRadius: cornerRadius, contains: point) { return row }
        }
        guard let current, let held = row(for: current), held.key.hasHoverPill else { return nil }
        let band = frame(held)
        let reach = rowSpacing + inset
        guard point.x >= band.minX, point.x < band.maxX,
              point.y >= band.minY - reach, point.y < band.maxY + reach else { return nil }
        return held
    }

    /// `rect` inset by `inset` top and bottom, with corners rounded by `cornerRadius`, contains `point`.
    static func pill(_ rect: CGRect, inset: CGFloat, cornerRadius: CGFloat, contains point: CGPoint) -> Bool {
        let pill = rect.insetBy(dx: 0, dy: inset)
        guard pill.width > 0, pill.height > 0, point.x >= pill.minX, point.x < pill.maxX,
              point.y >= pill.minY, point.y < pill.maxY else { return false }
        let r = max(0, min(cornerRadius, pill.width / 2, pill.height / 2))
        let cx = min(max(point.x, pill.minX + r), pill.maxX - r)
        let cy = min(max(point.y, pill.minY + r), pill.maxY - r)
        let dx = point.x - cx, dy = point.y - cy
        return dx * dx + dy * dy <= r * r
    }
}

extension SidebarRowKey {
    /// Rows that show hover controls and draw as a pill.
    var hasHoverPill: Bool {
        switch self {
        case .workspace, .tab: true
        default: false
        }
    }
}
