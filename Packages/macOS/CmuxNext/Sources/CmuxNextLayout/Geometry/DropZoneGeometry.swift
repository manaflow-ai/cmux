public import CoreGraphics

/// Hit testing and highlight rects for tab drops.
public nonisolated enum DropZoneGeometry {
    /// The zone of pane cell `rect` under `point`. The zones divide the
    /// pane body, below its `header`-point tab bar (flipped, y grows down):
    /// the tab bar joins the pane (center), an edge wins when the point is
    /// inside that edge's band of the body, else center. Corners go to the
    /// relatively nearer edge. The preview (`highlightRect`) and the commit
    /// both take the target from here (R47).
    public static func zone(at point: CGPoint, in rect: CGRect, header: CGFloat = 0, style: LayoutStyle) -> PaneDropZone {
        let top = rect.minY + min(max(0, header), rect.height)
        guard point.y >= top else { return .center }
        let body = CGRect(x: rect.minX, y: top, width: rect.width, height: rect.maxY - top)
        let bandX = band(for: body.width, style: style)
        let bandY = band(for: body.height, style: style)
        let candidates: [(PaneDropZone, CGFloat)] = [
            (.left, (point.x - body.minX) / bandX),
            (.right, (body.maxX - point.x) / bandX),
            (.top, (point.y - body.minY) / bandY),
            (.bottom, (body.maxY - point.y) / bandY),
        ]
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 < 1 else { return .center }
        return nearest.0
    }

    /// An edge band: a fraction of the extent within the style's range, and
    /// at most a third of it, so the middle third always joins the pane.
    static func band(for extent: CGFloat, style: LayoutStyle) -> CGFloat {
        let raw = extent * style.dropEdgeFraction
        let clamped = min(max(raw, style.dropEdgeRange.lowerBound), style.dropEdgeRange.upperBound)
        return max(1, min(clamped, extent / 3))
    }

    /// Drop target under `point` (content space). Column gap zones win over
    /// pane edges so "new column" is reachable between columns.
    public static func target(at point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, headers: [PaneID: CGFloat] = [:],
                              style: LayoutStyle) -> DropTarget? {
        for zone in geometry.gapZones where zone.frame.contains(point) {
            return .newColumn(screen: screen, after: zone.after)
        }
        for (pane, rect) in geometry.panes.sorted(by: { $0.key < $1.key }) where rect.contains(point) {
            return .pane(pane, zone(at: point, in: rect, header: header(of: pane, in: rect, headers, style), style: style))
        }
        return nil
    }

    /// The tab bar height of `pane` measured from its cell top: the cell's
    /// padding plus the header the pane reports (`headers`).
    static func header(of pane: PaneID, in cell: CGRect, _ headers: [PaneID: CGFloat], _ style: LayoutStyle) -> CGFloat {
        guard let header = headers[pane], header > 0 else { return 0 }
        return PaneChromeGeometry.contentRect(forCell: cell, style: style).minY - cell.minY + header
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
            return pane.map { .pane($0.key, zone(at: point, in: $0.value, header: header(of: $0.key, in: $0.value, headers, style),
                                                 style: style)) }
        }
        let content = CGPoint(x: point.x - geometry.viewShift(offset: offset), y: point.y)
        for zone in geometry.gapZones where zone.frame.contains(content) {
            return .newColumn(screen: screen, after: zone.after)
        }
        for (pane, rect) in geometry.panes.sorted(by: { $0.key < $1.key }) where geometry.scrolls(pane: pane) && rect.contains(content) {
            return .pane(pane, zone(at: content, in: rect, header: header(of: pane, in: rect, headers, style), style: style))
        }
        return nil
    }

    /// DD1: an edge band that opens a dock, while that edge has none (view
    /// coordinates). Nil elsewhere. Top and bottom bands are `dockDropBand`
    /// deep; the side bands are half that, so the outer panes keep their
    /// left and right split zones. Top and bottom win in the corners.
    /// `topInset` is the tab bar height at the top edge: the tab bar takes
    /// drops into the strip, so the top band starts below it (dogfood
    /// 2026-10-03: a band inside the tab bar was never reached).
    public static func dockTarget(atView point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, style: LayoutStyle,
                                  topInset: CGFloat = 0) -> DropTarget? {
        let size = geometry.viewport
        let band = min(style.dockDropBand, size.height / 4)
        let side = min(style.dockDropBand / 2, size.width / 8)
        let free = { (edge: StickyEdge) in !geometry.sticky.contains { $0.sticky.edge == edge } }
        if point.y >= topInset, point.y <= topInset + band, free(.top) { return .newDock(screen: screen, edge: .top) }
        if point.y >= size.height - band, free(.bottom) { return .newDock(screen: screen, edge: .bottom) }
        if point.x <= side, free(.left) { return .newDock(screen: screen, edge: .left) }
        if point.x >= size.width - side, free(.right) { return .newDock(screen: screen, edge: .right) }
        return nil
    }

    /// Where a new dock would sit (view coordinates): a band 30% of the
    /// height across the screen, or a side column 30% of the width down it,
    /// less the strip gaps.
    static func dockPreview(_ edge: StickyEdge, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect {
        let size = geometry.viewport
        let gap = style.stripGap
        if edge.isBand {
            let height = min(size.height * 0.3, size.height * StickyStripGeometry.maxBandShare)
            return CGRect(x: gap, y: edge == .top ? 0 : size.height - height, width: max(1, size.width - gap * 2), height: height)
        }
        let width = size.width * 0.3
        return CGRect(x: edge == .left ? gap : size.width - width - gap, y: 0, width: max(1, width), height: size.height)
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
