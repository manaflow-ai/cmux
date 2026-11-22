import AppKit

/// Tab drop hit testing: the target under a point, with the room check.
extension ScreenContentView {
    /// Drop target, its highlight rect and the region it belongs to (the
    /// whole pane content rect, or the column gap), in local coordinates.
    /// `removing`: the pane the drag empties (frees room; the commit obeys).
    /// `previous` is the zone hit the preview shows now (`hit`, before the
    /// room check), so the shown zone holds near its line.
    func dropTarget(at localPoint: NSPoint, removing: PaneID? = nil,
                    previous: DropTarget? = nil) -> (target: DropTarget, hit: DropTarget, highlight: CGRect, region: CGRect)? {
        // The top band starts below the tab bar of the pane under the pointer.
        let (topInset, bottomInset) = dockInsets(at: localPoint)
        if context.model.acceptsEdgeDockDrops,
           let dock = DropZoneGeometry.dockTarget(atView: localPoint, screen: screenID, geometry: geometry, style: context.style,
                                                  topInset: topInset, bottomInset: bottomInset),
           let rect = DropZoneGeometry.highlightRectInView(for: dock, offset: scroll.value, geometry: geometry, style: context.style) {
            return (dock, dock, rect, rect)
        }
        let (headers, footers) = paneChromeBands()
        guard let hit = DropZoneGeometry.target(atView: localPoint, offset: scroll.value, screen: screenID, geometry: geometry,
                                                headers: headers, footers: footers, style: context.style,
                                                previous: previous) else { return nil }
        let target = roomAdjusted(hit, removing: removing)
        guard var rect = DropZoneGeometry.highlightRectInView(for: target, offset: scroll.value, geometry: geometry,
                                                              style: context.style) else { return nil }
        // A strip target's highlight never draws over a docked column.
        if case let .pane(pane, _) = target, !geometry.scrolls(pane: pane) {} else { rect = rect.intersection(uncoveredRect) }
        guard !rect.isNull else { return nil }
        let region = DropZoneGeometry.regionRectInView(for: target, offset: scroll.value, geometry: geometry, style: context.style) ?? rect
        return (target, hit, rect, region)
    }

    /// Where splitting `pane` along `axis` goes on this screen right now.
    func splitPlacement(splitting pane: PaneID, axis: SplitAxis, removing: PaneID?) -> SplitPlacement {
        SplitRoom.placement(splitting: pane, axis: axis, in: layout, viewport: bounds.size, style: context.style, removing: removing)
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
