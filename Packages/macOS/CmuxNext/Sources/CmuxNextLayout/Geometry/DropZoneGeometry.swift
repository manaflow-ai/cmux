public import CoreGraphics

/// Hit testing and highlight rects for tab drops.
public nonisolated enum DropZoneGeometry {
    /// The zone of pane cell `rect` under `point`. The zones divide the
    /// pane body, below its `header`-point tab bar (flipped, y grows down):
    /// the tab bar joins the pane (center), an edge wins when the point is
    /// inside that edge's band of the body, else center. Corners go to the
    /// relatively nearer edge. The preview (`highlightRect`) and the commit
    /// both take the target from here (R47). `previous` is the zone the
    /// preview shows in this pane now.
    public static func zone(at point: CGPoint, in rect: CGRect, header: CGFloat = 0, footer: CGFloat = 0, style: LayoutStyle,
                            previous: PaneDropZone? = nil) -> PaneDropZone {
        let top = rect.minY + min(max(0, header), rect.height)
        let bottom = max(top, rect.maxY - max(0, footer))
        // Over the tab bar (header or footer) a tab joins the pane.
        guard point.y >= top, point.y < bottom || footer <= 0 else { return .center }
        let body = CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
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
    /// pane edges so "new column" is reachable between columns. A point in
    /// no pane goes to the nearest pane.
    public static func target(at point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, headers: [PaneID: CGFloat] = [:],
                              footers: [PaneID: CGFloat] = [:], style: LayoutStyle, previous: DropTarget? = nil) -> DropTarget? {
        for zone in geometry.gapZones where zone.frame.contains(point) {
            return .newColumn(screen: screen, after: zone.after)
        }
        let candidates = geometry.panes.map { (pane: $0.key, cell: $0.value, visible: $0.value) }
        return paneTarget(at: point, candidates, headers: headers, footers: footers, style: style, previous: previous)
    }

    /// The tab bar height of `pane` measured from its cell top: the cell's
    /// padding plus the header the pane reports (`headers`).
    static func header(of pane: PaneID, in cell: CGRect, _ headers: [PaneID: CGFloat], _ style: LayoutStyle) -> CGFloat {
        guard let header = headers[pane], header > 0 else { return 0 }
        return PaneChromeGeometry.contentRect(forCell: cell, style: style).minY - cell.minY + header
    }

    /// The tab bar height of `pane` at the bottom of its cell (R109): the
    /// cell's padding plus the footer the pane reports (`footers`).
    static func footer(of pane: PaneID, in cell: CGRect, _ footers: [PaneID: CGFloat], _ style: LayoutStyle) -> CGFloat {
        guard let footer = footers[pane], footer > 0 else { return 0 }
        return cell.maxY - PaneChromeGeometry.contentRect(forCell: cell, style: style).maxY + footer
    }

    /// Drop target under `point` in view coordinates, with the strip
    /// scrolled to `offset`. Docked columns sit above the strip: their panes
    /// take the drop, and the rest of what a docked column covers (its glass
    /// rim, a docked column's edge band) goes to the nearest docked pane, so
    /// nothing lands in a strip pane hidden under it. The strip resolves as
    /// `target(at:)`. Every point resolves while the screen has a pane.
    /// `previous` is the target the preview shows now.
    public static func target(atView point: CGPoint, offset: CGFloat, screen: ScreenID, geometry: ScreenGeometry,
                              headers: [PaneID: CGFloat] = [:], footers: [PaneID: CGFloat] = [:], style: LayoutStyle,
                              previous: DropTarget? = nil) -> DropTarget? {
        let shift = geometry.viewShift(offset: offset)
        if let cover = geometry.dock.first(where: { $0.cover.contains(point) }) {
            let panes = geometry.panes.filter { geometry.fixedPanes.contains($0.key) && cover.frame.contains($0.value) }
            return paneTarget(at: point, panes.map { (pane: $0.key, cell: $0.value, visible: $0.value) }, headers: headers,
                              footers: footers, style: style, previous: previous)
        }
        let content = CGPoint(x: point.x - shift, y: point.y)
        for zone in geometry.gapZones where zone.frame.contains(content) {
            return .newColumn(screen: screen, after: zone.after)
        }
        // Every pane, in view coordinates, clipped to what the docks leave
        // visible: the pane the point is in, else the nearest one.
        let uncovered = geometry.dock.isEmpty ? nil : CGRect(x: geometry.uncoveredMinX, y: geometry.uncoveredMinY,
                                                             width: geometry.uncoveredMaxX - geometry.uncoveredMinX,
                                                             height: geometry.uncoveredMaxY - geometry.uncoveredMinY)
        let candidates = geometry.panes.compactMap { entry -> (pane: PaneID, cell: CGRect, visible: CGRect)? in
            let (pane, rect) = (entry.key, entry.value)
            guard geometry.scrolls(pane: pane) else { return (pane, rect, rect) }
            let cell = rect.offsetBy(dx: shift, dy: 0)
            guard let uncovered else { return (pane, cell, cell) }
            let visible = cell.intersection(uncovered)
            return visible.isNull || visible.isEmpty ? nil : (pane, cell, visible)
        }
        return paneTarget(at: point, candidates, headers: headers, footers: footers, style: style, previous: previous)
    }

    /// The pane target under `point`: the pane whose cell holds it, else
    /// the pane nearest to it, with the zone at the nearest point of that
    /// pane (tab-dnd: no dead zones, so the gutters, the padding and a
    /// docked column's rim preview the pane next to them; Lawrence
    /// 2026-10-04). `visible` is the part of the cell nothing covers.
    static func paneTarget(at point: CGPoint, _ candidates: [(pane: PaneID, cell: CGRect, visible: CGRect)],
                           headers: [PaneID: CGFloat], footers: [PaneID: CGFloat] = [:], style: LayoutStyle,
                           previous: DropTarget? = nil) -> DropTarget? {
        let sorted = candidates.sorted { $0.pane < $1.pane }
        func resolve(_ point: CGPoint, _ pane: PaneID, _ cell: CGRect) -> PaneDropZone {
            Self.zone(at: point, in: cell, header: header(of: pane, in: cell, headers, style),
                      footer: footer(of: pane, in: cell, footers, style), style: style)
        }
        if let hit = sorted.first(where: { $0.visible.contains(point) }) {
            return .pane(hit.pane, resolve(point, hit.pane, hit.cell))
        }
        guard let nearest = sorted.min(by: { distance(point, $0.visible) < distance(point, $1.visible) }) else { return nil }
        return .pane(nearest.pane, resolve(clamp(point, into: nearest.visible), nearest.pane, nearest.cell))
    }

    static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func clamp(_ point: CGPoint, into rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    /// DD1: an edge band that opens a dock, while that edge has none (view
    /// coordinates). Nil elsewhere. Top and bottom bands are `dockDropBand`
    /// deep; the side bands are half that, so the outer panes keep their
    /// left and right split zones. Top and bottom win in the corners.
    /// `topInset` is the tab bar height at the top edge: the tab bar takes
    /// drops into the strip, so the top band starts below it (dogfood
    /// 2026-10-03: a band inside the tab bar was never reached).
    /// `bottomInset` is the same for a tab bar at the bottom (R109).
    public static func dockTarget(atView point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, style: LayoutStyle,
                                  topInset: CGFloat = 0, bottomInset: CGFloat = 0) -> DropTarget? {
        let size = geometry.viewport
        let band = min(style.dockDropBand, size.height / 4)
        let topBand = min(style.dockTopDropBand, size.height / 4)
        let side = min(style.dockDropBand / 2, size.width / 8)
        let free = { (edge: DockEdge) in !geometry.dock.contains { $0.dock.edge == edge } }
        if point.y >= topInset, point.y <= topInset + topBand, free(.top) { return .newDock(screen: screen, edge: .top) }
        let bottom = size.height - bottomInset
        if point.y >= bottom - band, point.y <= bottom, free(.bottom) { return .newDock(screen: screen, edge: .bottom) }
        if point.x <= side, free(.left) { return .newDock(screen: screen, edge: .left) }
        if point.x >= size.width - side, free(.right) { return .newDock(screen: screen, edge: .right) }
        return nil
    }

    /// Where a new dock would sit (view coordinates): a band 30% of the
    /// height across the screen, or a side column 30% of the width down it,
    /// less the strip gaps.
    static func dockPreview(_ edge: DockEdge, geometry: ScreenGeometry, style: LayoutStyle) -> CGRect {
        let size = geometry.viewport
        let gap = style.stripGap
        if edge.isBand {
            let height = min(size.height * 0.3, size.height * DockStripGeometry.maxBandShare)
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
