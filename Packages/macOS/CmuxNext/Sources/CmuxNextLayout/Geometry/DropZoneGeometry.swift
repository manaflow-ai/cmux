public import CoreGraphics

/// Hit testing and highlight rects for tab drops.
public nonisolated enum DropZoneGeometry {
    /// The zone of `rect` under `point`: an edge when the point sits inside
    /// that edge's band, else center. Corners go to the relatively nearer edge.
    public static func zone(at point: CGPoint, in rect: CGRect, header: CGFloat = 0, style: LayoutStyle) -> PaneDropZone {
        let bandX = band(for: rect.width, style: style)
        let bandY = band(for: rect.height, style: style)
        let candidates: [(PaneDropZone, CGFloat)] = [
            (.left, (point.x - rect.minX) / bandX),
            (.right, (rect.maxX - point.x) / bandX),
            (.top, (point.y - rect.minY) / bandY),
            (.bottom, (rect.maxY - point.y) / bandY),
        ]
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 < 1 else { return .center }
        return nearest.0
    }

    static func band(for extent: CGFloat, style: LayoutStyle) -> CGFloat {
        let raw = extent * style.dropEdgeFraction
        let clamped = min(max(raw, style.dropEdgeRange.lowerBound), style.dropEdgeRange.upperBound)
        return max(1, min(clamped, extent / 2))
    }

    /// Drop target under `point` (content space). Column gap zones win over
    /// pane edges so "new column" is reachable between columns.
    public static func target(at point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, headers: [PaneID: CGFloat] = [:],
                              style: LayoutStyle) -> DropTarget? {
        for zone in geometry.gapZones where zone.frame.contains(point) {
            return .newColumn(screen: screen, after: zone.after)
        }
        for (pane, rect) in geometry.panes.sorted(by: { $0.key < $1.key }) where rect.contains(point) {
            return .pane(pane, zone(at: point, in: rect, style: style))
        }
        return nil
    }

    /// Drop target under `point` in view coordinates, with the strip
    /// scrolled to `offset`. Sticky columns sit above the strip: their panes
    /// take the drop, and the rest of what a sticky column covers (its glass
    /// rim, a docked column's edge band) takes none, so nothing lands in a
    /// strip pane hidden under it. The strip resolves as `target(at:)`.
    public static func target(atView point: CGPoint, offset: CGFloat, screen: ScreenID, geometry: ScreenGeometry,
                              headers: [PaneID: CGFloat] = [:], style: LayoutStyle) -> DropTarget? {
        if let cover = geometry.sticky.first(where: { $0.cover.contains(point) }) {
            let pane = geometry.panes.filter { geometry.fixedPanes.contains($0.key) && cover.frame.contains($0.value) }
                .sorted { $0.key < $1.key }.first { $0.value.contains(point) }
            return pane.map { .pane($0.key, zone(at: point, in: $0.value, style: style)) }
        }
        let content = CGPoint(x: point.x - geometry.viewShift(offset: offset), y: point.y)
        for zone in geometry.gapZones where zone.frame.contains(content) {
            return .newColumn(screen: screen, after: zone.after)
        }
        for (pane, rect) in geometry.panes.sorted(by: { $0.key < $1.key }) where geometry.scrolls(pane: pane) && rect.contains(content) {
            return .pane(pane, zone(at: content, in: rect, style: style))
        }
        return nil
    }

    /// DD1: a top or bottom edge band that opens a dock, while that edge has
    /// none (view coordinates). Nil elsewhere.
    public static func dockTarget(atView point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, style: LayoutStyle) -> DropTarget? {
        let band = min(style.dockDropBand, geometry.viewport.height / 4)
        let free = { (edge: StickyEdge) in !geometry.sticky.contains { $0.sticky.edge == edge } }
        if point.y <= band, free(.top) { return .newDock(screen: screen, edge: .top) }
        if point.y >= geometry.viewport.height - band, free(.bottom) { return .newDock(screen: screen, edge: .bottom) }
        return nil
    }

    /// Where a new top or bottom dock would sit (view coordinates): a third
    /// of the height, at most half, across the screen less its gaps.
    static func dockPreview(_ edge: StickyEdge, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect {
        let size = geometry.viewport
        let height = min(size.height * 0.3, size.height * StickyStripGeometry.maxBandShare)
        let gap = style.stripGap
        return CGRect(x: gap, y: edge == .top ? 0 : size.height - height, width: max(1, size.width - gap * 2), height: height)
    }

    /// The whole region a drop on `target` divides (content space): the
    /// pane's rounded content rect, or the column gap zone.
    public static func regionRect(for target: DropTarget, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect? {
        switch target {
        case let .pane(pane, _):
            return geometry.panes[pane].map { PaneChromeGeometry.contentRect(forCell: $0, style: style) }
        case let .newColumn(_, after):
            return geometry.gapZones.first(where: { $0.after == after })?.frame
        case let .newDock(_, edge):
            return dockPreview(edge, geometry: geometry, style: style)
        }
    }

    /// `regionRect(for:)` in view coordinates with the strip at `offset`.
    public static func regionRectInView(for target: DropTarget, offset: CGFloat, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect? {
        guard let rect = regionRect(for: target, geometry: geometry, style: style) else { return nil }
        if case .newDock = target { return rect }
        if case let .pane(pane, _) = target, !geometry.scrolls(pane: pane) { return rect }
        return rect.offsetBy(dx: geometry.viewShift(offset: offset), dy: 0)
    }

    /// `highlightRect(for:)` in view coordinates with the strip at `offset`.
    public static func highlightRectInView(for target: DropTarget, offset: CGFloat, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect? {
        guard let rect = highlightRect(for: target, geometry: geometry, style: style) else { return nil }
        if case .newDock = target { return rect }
        if case let .pane(pane, _) = target, !geometry.scrolls(pane: pane) { return rect }
        return rect.offsetBy(dx: geometry.viewShift(offset: offset), dy: 0)
    }

    /// Where the glass highlight goes for `target` (content space).
    public static func highlightRect(for target: DropTarget, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect? {
        switch target {
        case let .pane(pane, zone):
            guard let cell = geometry.panes[pane] else { return nil }
            let rect = PaneChromeGeometry.contentRect(forCell: cell, style: style)
            switch zone {
            case .center: return rect
            case .left: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
            case .right: return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
            case .top: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
            case .bottom: return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
            }
        case let .newColumn(_, after):
            guard let zone = geometry.gapZones.first(where: { $0.after == after }) else { return nil }
            return zone.frame
        case let .newDock(_, edge):
            return dockPreview(edge, geometry: geometry, style: style)
        }
    }
}
