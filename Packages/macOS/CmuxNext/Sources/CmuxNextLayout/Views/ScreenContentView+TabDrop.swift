import AppKit

/// Tab drop hit testing: the target under a point, with the room check.
extension ScreenContentView {
    /// Drop target, its highlight rect and the region it belongs to (the
    /// whole pane content rect, or the column gap), in local coordinates.
    /// `removing`: the pane the drag empties (frees room; the commit obeys).
    /// `previous` is the target hit the preview shows now (`hit`, before the
    /// room check): panes, docks and column gaps hold near their lines with
    /// `dropZoneHysteresis`. Docks and gaps shrink for entry from the split
    /// zone that faces them; dock, gap and pane priority stays the same.
    /// `edgesArmed` false: a pane edge (a new split) joins the pane instead, until the drag has
    /// held that edge (`LayoutRootView.updateTabDrag`'s dwell); `hit` stays the edge.
    /// `joinsFrom`: a terminal tab's source pane (`DropZoneGeometry.joiningSharedEdge`).
    func dropTarget(at localPoint: NSPoint, removing: PaneID? = nil, joinsFrom: PaneID? = nil, previous: DropTarget? = nil,
                    edgesArmed: Bool = true)
        -> (target: DropTarget, hit: DropTarget, highlight: CGRect, region: CGRect, companions: [CGRect])? {
        // The top band starts below the tab bar of the pane under the pointer.
        let (topInset, bottomInset) = dockInsets(at: localPoint)
        if context.model.acceptsEdgeDockDrops,
           let dock = DropZoneGeometry.dockTarget(atView: localPoint, screen: screenID, geometry: geometry, style: context.style,
                                                  topInset: topInset, bottomInset: bottomInset, previous: previous),
           let rect = DropZoneGeometry.highlightRectInView(for: dock, offset: scroll.value, geometry: geometry, style: context.style) {
            return (dock, dock, rect, rect, [])
        }
        let (headers, footers) = paneChromeBands()
        guard var zoneHit = DropZoneGeometry.target(atView: localPoint, offset: scroll.value, screen: screenID, geometry: geometry,
                                                    headers: headers, footers: footers, style: context.style,
                                                    previous: previous) else { return nil }
        // A pinned dock (the Home Chief pane) never splits: a tab dropped anywhere over it joins it.
        // One that takes no other tab (`allow_tabs` off) takes no drop at all: the join would only be
        // refused (`dock-column-pinned`), so nothing promises one.
        if case let .pane(pane, _) = zoneHit, let dock = layout.column(containing: pane)?.dock, dock.isPinned {
            guard dock.takesTabs else { return nil }
            zoneHit = .pane(pane, .center)
        }
        let hit = DropZoneGeometry.joiningSharedEdge(zoneHit, from: joinsFrom, frames: navigationFrames)
        let target: DropTarget
        if !edgesArmed, case let .pane(pane, zone) = hit, zone != .center {
            target = .pane(pane, .center)
        } else {
            target = roomAdjusted(hit, removing: removing)
        }
        guard var rect = DropZoneGeometry.highlightRectInView(for: target, offset: scroll.value, geometry: geometry,
                                                              style: context.style) else { return nil }
        var companions: [CGRect] = []
        // An edge shows the layout the drop makes (DESIGN.md (c)1): the new pane filled, and every pane the
        // split resizes or moves outlined at its final frame.
        if case let .pane(pane, zone) = target, zone != .center, let preview = finalLayoutPreview(splitting: pane, zone: zone, removing: removing) {
            rect = preview.newPane
            companions = preview.resized
        } else if case let .pane(pane, zone) = target, let body = paneBody(pane, headers: headers, footers: footers) {
            rect = DropZoneGeometry.classicPaneHighlight(body: body, zone: zone)
        }
        // A strip target's highlight never draws over a docked column.
        if case let .pane(pane, _) = target, !geometry.scrolls(pane: pane) {} else { rect = rect.intersection(uncoveredRect) }
        guard !rect.isNull else { return nil }
        let region = DropZoneGeometry.regionRectInView(for: target, offset: scroll.value, geometry: geometry, style: context.style) ?? rect
        return (target, hit, rect, region, companions)
    }

    /// `pane`'s body in view coordinates: its content rect below its tab bar (and above a bottom
    /// tab bar), the area its drop zones divide.
    func paneBody(_ pane: PaneID, headers: [PaneID: CGFloat], footers: [PaneID: CGFloat]) -> CGRect? {
        guard let cell = geometry.panes[pane],
              let content = DropZoneGeometry.regionRectInView(for: .pane(pane, .center), offset: scroll.value, geometry: geometry,
                                                              style: context.style) else { return nil }
        let shown = geometry.scrolls(pane: pane) ? cell.offsetBy(dx: geometry.viewShift(offset: scroll.value), dy: 0) : cell
        let top = max(content.minY, shown.minY + DropZoneGeometry.header(of: pane, in: cell, headers, context.style))
        let bottom = min(content.maxY, shown.maxY - DropZoneGeometry.footer(of: pane, in: cell, footers, context.style))
        return CGRect(x: content.minX, y: top, width: content.width, height: max(0, bottom - top))
    }

    /// The join preview of `pane` (view coordinates): the same body fill a tab dropped in its center
    /// shows. A pane drag previews its target with it, so both drags share one preview.
    func joinHighlight(_ pane: PaneID) -> (highlight: CGRect, region: CGRect)? {
        let (headers, footers) = paneChromeBands()
        guard let body = paneBody(pane, headers: headers, footers: footers),
              let region = DropZoneGeometry.regionRectInView(for: .pane(pane, .center), offset: scroll.value, geometry: geometry,
                                                             style: context.style) else { return nil }
        var rect = DropZoneGeometry.classicPaneHighlight(body: body, zone: .center)
        if geometry.scrolls(pane: pane) { rect = rect.intersection(uncoveredRect) }
        return rect.isNull || rect.isEmpty ? nil : (rect, region)
    }

    /// The new pane's rect and the final rects of the panes a split of `pane` at `zone` resizes or
    /// moves (view coordinates, inset 2 pt so neighbors read apart); nil when the layout cannot be
    /// predicted here, and the caller falls back to the half.
    private func finalLayoutPreview(splitting pane: PaneID, zone: PaneDropZone, removing: PaneID?) -> (newPane: CGRect, resized: [CGRect])? {
        // The drop sends this prediction's ratios once its move landed (`LayoutModel.dropSizingChanges`,
        // TabMoves.toNewSplit), so the preview shows exactly the layout that lands.
        guard let predicted = DropPreviewLayout(splitting: pane, zone: zone, in: layout, removing: removing,
                                                evenSizing: context.model.splitSizing == .even, equalizesClose: !zoomed) else { return nil }
        // A drop that closes a column moves the strip's camera after it; show the half rather than guess.
        if case let .columns(before) = layout, case let .columns(after) = predicted.layout, before.map(\.id) != after.map(\.id) {
            return nil
        }
        let style = context.style
        let after = ScreenGeometry.compute(predicted.layout, viewport: bounds.size, style: style, scale: window?.backingScaleFactor ?? 2)
        let offset = scroll.value
        func shown(_ cell: CGRect, _ pane: PaneID, in geometry: ScreenGeometry) -> CGRect {
            let content = PaneChromeGeometry.contentRect(forCell: cell, style: style)
            let shift = geometry.scrolls(pane: pane) ? geometry.viewShift(offset: offset) : 0
            return content.offsetBy(dx: shift, dy: 0).insetBy(dx: 2, dy: 2)
        }
        guard let cell = after.panes[DropPreviewLayout.newPane] else { return nil }
        let newPane = shown(cell, DropPreviewLayout.newPane, in: after)
        // The new pane must be fully on screen, or the drop's focus reveal scrolls the strip: show the half.
        guard bounds.insetBy(dx: -1, dy: -1).contains(newPane) else { return nil }
        var resized: [CGRect] = []
        for (other, frame) in after.panes where other != DropPreviewLayout.newPane {
            let before = geometry.panes[other].map { shown($0, other, in: geometry) }
            let now = shown(frame, other, in: after)
            if let before, abs(before.minX - now.minX) + abs(before.minY - now.minY) + abs(before.width - now.width)
                + abs(before.height - now.height) < 1 { continue }
            resized.append(now)
        }
        return (newPane, resized.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) })
    }

    /// Where splitting `pane` along `axis` goes on this screen right now.
    func splitPlacement(splitting pane: PaneID, axis: SplitAxis, removing: PaneID?) -> SplitPlacement {
        // A canvas places a split's new pane beside the old one at its size: there is always room.
        if isCanvas { return .split }
        return SplitRoom.placement(splitting: pane, axis: axis, in: layout, viewport: bounds.size, style: context.style, removing: removing)
    }

    /// An edge drop that cannot split for lack of room becomes a new column
    /// beside the pane's column (columns screen, side edge) or joins the pane.
    private func roomAdjusted(_ target: DropTarget, removing: PaneID?) -> DropTarget {
        guard case let .pane(pane, zone) = target, let axis = zone.splitAxis else { return target }
        switch splitPlacement(splitting: pane, axis: axis, removing: removing == pane ? nil : removing) {
        case .split:
            return target
        case .newColumn:
            // A docked column never grows a neighbor column: join it instead.
            guard geometry.scrolls(pane: pane), let column = layout.column(containing: pane),
                  let index = geometry.columnOrder.firstIndex(of: column.id) else {
                return .pane(pane, .center)
            }
            let after = zone == .left ? (index > 0 ? geometry.columnOrder[index - 1] : nil) : column.id
            return .newColumn(screen: screenID, after: after)
        case .refused:
            return .pane(pane, .center)
        }
    }
}
