public import CoreGraphics

/// Hit testing and highlight rects for tab drops.
public nonisolated enum DropZoneGeometry {
    /// The zone of pane cell `rect` under `point` (pane-drop-targets
    /// DESIGN.md (c), the first-principles rule): the zones divide the pane
    /// body below its `header`-point tab bar (flipped, y grows down); over
    /// the tab bar a tab joins the pane (center). Each edge owns a band
    /// (`band(for:)`); a point inside several bands (a corner) goes to the
    /// edge it is relatively nearest to (depth / band), so a corner splits
    /// along the edge the pointer is closer to; else center. The preview
    /// (`highlightRect`) and the commit both take the target from here
    /// (R47). `previous` is the zone the preview shows in this pane now: it
    /// holds until the pointer is `dropZoneHysteresis` past its line, so a
    /// pointer held on a line never flickers.
    public static func zone(at point: CGPoint, in rect: CGRect, header: CGFloat = 0, footer: CGFloat = 0, style: LayoutStyle,
                            previous: PaneDropZone? = nil) -> PaneDropZone {
        let top = rect.minY + min(max(0, header), rect.height)
        let bottom = max(top, rect.maxY - max(0, footer))
        // Over the tab bar (header or footer) a tab joins the pane.
        guard point.y >= top, point.y < bottom || footer <= 0 else { return .center }
        let body = CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
        let bandX = band(for: body.width, style: style)
        let bandY = band(for: body.height, style: style)
        let margin = max(0, style.dropZoneHysteresis)
        // Depth into each edge's band as a share of the band (< 1 is inside).
        func reach(_ zone: PaneDropZone) -> CGFloat {
            let extra: CGFloat = switch previous {
            case zone?: margin
            case .center?: -min(margin, (zone.splitAxis == .horizontal ? bandX : bandY) / 2)
            default: 0
            }
            return switch zone {
            case .left: (point.x - body.minX) / max(1, bandX + extra)
            case .right: (body.maxX - point.x) / max(1, bandX + extra)
            case .top: (point.y - body.minY) / max(1, bandY + extra)
            case .bottom: (body.maxY - point.y) / max(1, bandY + extra)
            case .center: .infinity
            }
        }
        if let previous, previous != .center, reach(previous) < 1 { return previous }
        let candidates = [PaneDropZone.left, .right, .top, .bottom].map { ($0, reach($0)) }.filter { $0.1 < 1 }
        return candidates.min { $0.1 < $1.1 }?.0 ?? .center
    }

    /// An edge band: a share of the extent above the style's floor
    /// (`dropEdgeFraction` 0.25, at least 48 pt, no cap), and never more
    /// than a third of it, so every pane keeps a center of at least a third
    /// of each axis to join (plans/cmux-next/drop-zones/DESIGN.md).
    static func band(for extent: CGFloat, style: LayoutStyle) -> CGFloat {
        let raw = extent * style.dropEdgeFraction
        let clamped = min(max(raw, style.dropEdgeRange.lowerBound), style.dropEdgeRange.upperBound)
        return max(1, min(clamped, extent / 3))
    }

    /// Drop target under `point` (content space). Column gap zones win over
    /// pane edges so "new column" is reachable between columns. The shown
    /// gap holds `dropZoneHysteresis` horizontally past its frame; entered
    /// from a left or right split zone it shrinks by at most a quarter of
    /// its width (`gapTarget`). A point in no pane goes to the nearest pane,
    /// with its own zone hysteresis.
    public static func target(at point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, headers: [PaneID: CGFloat] = [:],
                              footers: [PaneID: CGFloat] = [:], style: LayoutStyle, previous: DropTarget? = nil) -> DropTarget? {
        if let gap = gapTarget(at: point, screen: screen, geometry: geometry, style: style, previous: previous) { return gap }
        let candidates = geometry.panes.map { (pane: $0.key, cell: $0.value, visible: $0.value) }
        return paneTarget(at: point, candidates, headers: headers, footers: footers, style: style, previous: previous)
    }

    /// A column gap grows horizontally while shown. Entered from a pane's left or right split
    /// zone (the drag pushing toward the pane edge beside the gap), it shrinks by at most a
    /// quarter of its width, so the split holds near the line; from anywhere else it keeps its frame.
    static func gapTarget(at point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, style: LayoutStyle,
                          previous: DropTarget? = nil) -> DropTarget? {
        let margin = max(0, style.dropZoneHysteresis)
        for zone in geometry.gapZones {
            let target = DropTarget.newColumn(screen: screen, after: zone.after)
            let inset: CGFloat = switch previous {
            case target?: -margin
            case .pane(_, .left)?, .pane(_, .right)?: min(margin, zone.frame.width / 4)
            default: 0
            }
            if zone.frame.insetBy(dx: inset, dy: 0).contains(point) { return target }
        }
        return nil
    }

    /// bonsplit's shared edge (#22287): a terminal tab dragged out of
    /// `source` onto the band of the pane beside it that faces `source`
    /// joins that pane instead of splitting it; the pane's outer edge still
    /// splits. Only left and right, as in bonsplit. `frames` are the panes
    /// in one logical line (`ScreenContentView.navigationFrames`); the
    /// neighbor is `FocusNavigation`'s, and must overlap `source` vertically
    /// (its fallback to the nearest pane shares no edge).
    public static func joiningSharedEdge(_ target: DropTarget, from source: PaneID?, frames: [PaneID: CGRect]) -> DropTarget {
        guard let source, case let .pane(pane, zone) = target, pane != source else { return target }
        let toward: LayoutDirection
        switch zone {
        case .left: toward = .right
        case .right: toward = .left
        case .top, .bottom, .center: return target
        }
        guard let from = frames[source], let to = frames[pane], min(from.maxY, to.maxY) > max(from.minY, to.minY),
              FocusNavigation.neighbor(of: source, direction: toward, frames: frames) == pane else { return target }
        return .pane(pane, .center)
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
    /// `previous` is the target the preview shows now: pane zones hold near
    /// their lines, and gaps grow while shown or shrink for entry from a
    /// split zone, using `dropZoneHysteresis` as in `target(at:)`.
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
        if let gap = gapTarget(at: content, screen: screen, geometry: geometry, style: style, previous: previous) { return gap }
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
            let shown: PaneDropZone? = if case let .pane(previousPane, zone)? = previous, previousPane == pane { zone } else { nil }
            return Self.zone(at: point, in: cell, header: header(of: pane, in: cell, headers, style),
                             footer: footer(of: pane, in: cell, footers, style), style: style, previous: shown)
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
    /// coordinates). Nil elsewhere. The top band is `dockTopDropBand` deep,
    /// the bottom `dockDropBand`; the side bands are half `dockDropBand`, so
    /// the outer panes keep their left and right split zones. Top and bottom
    /// win in the corners. The same dock in `previous` grows its band inward
    /// by `dropZoneHysteresis`. Entered from the pane split zone that faces
    /// the same edge (a drag pushing a split toward the window edge), the
    /// band shrinks toward the edge by at most half its depth, so the split
    /// holds near the line; from anywhere else the band keeps its depth.
    /// `topInset` is the tab bar height at the top edge: the tab bar takes
    /// drops into the strip, so the top band starts below it (dogfood
    /// 2026-10-03: a band inside the tab bar was never reached).
    /// `bottomInset` is the same for a tab bar at the bottom (R109).
    public static func dockTarget(atView point: CGPoint, screen: ScreenID, geometry: ScreenGeometry, style: LayoutStyle,
                                  topInset: CGFloat = 0, bottomInset: CGFloat = 0, previous: DropTarget? = nil) -> DropTarget? {
        let size = geometry.viewport
        let band = min(style.dockDropBand, size.height / 4)
        let topBand = min(style.dockTopDropBand, size.height / 4)
        let side = min(style.dockDropBand / 2, size.width / 8)
        let margin = max(0, style.dropZoneHysteresis)
        func extra(_ edge: DockEdge, _ depth: CGFloat) -> CGFloat {
            if previous == .newDock(screen: screen, edge: edge) { return margin }
            guard case let .pane(_, zone)? = previous, zone.rawValue == edge.rawValue else { return 0 }
            return -min(margin, depth / 2)
        }
        let free = { (edge: DockEdge) in !geometry.dock.contains { $0.dock.edge == edge } }
        if point.y >= topInset, point.y <= topInset + topBand + extra(.top, topBand), free(.top) { return .newDock(screen: screen, edge: .top) }
        let bottom = size.height - bottomInset
        if point.y >= bottom - band - extra(.bottom, band), point.y <= bottom, free(.bottom) { return .newDock(screen: screen, edge: .bottom) }
        if point.x <= side + extra(.left, side), free(.left) { return .newDock(screen: screen, edge: .left) }
        if point.x >= size.width - side - extra(.right, side), free(.right) { return .newDock(screen: screen, edge: .right) }
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

    /// Classic cmux's pane drop overlay (`compactOverlayFrame`, padding 4):
    /// the pane body below its tab bar inset 4 pt for center; a half for an
    /// edge, inset 4 pt on its three outer sides and meeting the midline.
    /// The half is the size the split gives the new pane (0.5).
    public static func classicPaneHighlight(body: CGRect, zone: PaneDropZone, padding: CGFloat = 4) -> CGRect {
        let (x, y, w, h) = (body.minX, body.minY, body.width, body.height)
        let rect: CGRect = switch zone {
        case .center: CGRect(x: x + padding, y: y + padding, width: w - padding * 2, height: h - padding * 2)
        case .left: CGRect(x: x + padding, y: y + padding, width: body.midX - x - padding, height: h - padding * 2)
        case .right: CGRect(x: body.midX, y: y + padding, width: body.maxX - body.midX - padding, height: h - padding * 2)
        case .top: CGRect(x: x + padding, y: y + padding, width: w - padding * 2, height: body.midY - y - padding)
        case .bottom: CGRect(x: x + padding, y: body.midY, width: w - padding * 2, height: body.maxY - body.midY - padding)
        }
        return CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width), height: max(0, rect.height))
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
