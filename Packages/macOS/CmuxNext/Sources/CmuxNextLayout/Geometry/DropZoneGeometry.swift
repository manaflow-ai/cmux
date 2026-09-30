public import CoreGraphics

/// Hit testing and highlight rects for tab drops.
public nonisolated enum DropZoneGeometry {
    /// The zone of `rect` under `point`: an edge when the point sits inside
    /// that edge's band, else center. Corners go to the relatively nearer edge.
    public static func zone(at point: CGPoint, in rect: CGRect, style: LayoutStyle) -> PaneDropZone {
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
    public static func target(at point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, style: LayoutStyle) -> DropTarget? {
        for zone in geometry.gapZones where zone.frame.contains(point) {
            return .newColumn(screen: screen, after: zone.after)
        }
        for (pane, rect) in geometry.panes.sorted(by: { $0.key < $1.key }) where rect.contains(point) {
            return .pane(pane, zone(at: point, in: rect, style: style))
        }
        return nil
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
        }
    }
}
