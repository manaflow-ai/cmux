public import CoreGraphics

/// Which row the pointer hovers. From rest, a row with hover controls (a
/// workspace row) takes the hover only inside its hover pill, a hit
/// shape inside the drawn fill (nothing draws it): the row's frame inset by
/// `inset` top and bottom, with corners rounded by `cornerRadius` (Leo
/// 2026-10-19). Once a row is hovered, the hover follows the pointer: inside
/// another row's drawn frame that row takes it at once, so the old row never
/// stays lit under a pointer on the next one (Leo 2026-10-20: "hover must
/// follow the pointer instantly ... only one row hovered at a time"). Only the
/// gap between rows keeps the row hovered now, so a sweep down or up the list
/// never drops it between rows (#20315). The margin beside a row hovers nothing.
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
            // A pointer moving off the hovered row onto another row's fill: that row, at once.
            if let current, current != row.key, frame(row).contains(point) { return row }
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
    /// Rows that show hover controls, so they take the hover only inside their hover pill.
    var hasHoverPill: Bool {
        switch self {
        case .workspace: true
        default: false
        }
    }
}
