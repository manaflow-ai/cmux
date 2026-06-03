import CoreGraphics
import Foundation

/// Maps a drag cursor position to a ``SidebarDropIndicator`` for the gesture
/// driven workspace reorder, with hysteresis so the gap does not flicker when
/// the cursor hovers exactly on a row's midpoint.
///
/// Pure and self-contained so it is unit-testable without a running app: the
/// caller passes the reorder-scope rows as vertical bands (already resolved
/// from the live row frames) plus the current cursor Y, all in one coordinate
/// space. Edge/insertion/pinned-tier legality is delegated to
/// ``SidebarDropPlanner``; this type only adds hit-testing and stickiness.
enum SidebarReorderIndicatorResolver {
    /// One reorder-scope item's vertical extent in list space. For a top-level
    /// group drag, a band spans the group header plus all its member rows so
    /// the whole group reads as one target.
    struct Band: Equatable {
        let id: UUID
        let minY: CGFloat
        let maxY: CGFloat

        var midY: CGFloat { (minY + maxY) / 2 }
        var height: CGFloat { max(maxY - minY, 0) }
    }

    /// Resolves the drop indicator for `cursorY`.
    ///
    /// - Parameters:
    ///   - cursorY: cursor Y in the same list space as the band extents.
    ///   - bands: reorder-scope bands in scope order, contiguous and sorted.
    ///   - draggedId: the workspace being dragged.
    ///   - pinnedIds: pinned ids within the scope (tier constraint).
    ///   - current: the indicator currently shown, used for hysteresis.
    ///   - hysteresisMargin: half-width of the dead-zone around a band midpoint
    ///     within which the current edge is kept (points).
    /// - Returns: the indicator to show, or nil for a no-op move.
    static func resolve(
        cursorY: CGFloat,
        bands: [Band],
        draggedId: UUID,
        pinnedIds: Set<UUID>,
        current: SidebarDropIndicator?,
        hysteresisMargin: CGFloat
    ) -> SidebarDropIndicator? {
        guard !bands.isEmpty else { return nil }
        let scopeIds = bands.map(\.id)

        // Below every row: append to the end of the scope.
        guard let lastBand = bands.last, cursorY <= lastBand.maxY else {
            return SidebarDropPlanner.indicator(
                draggedTabId: draggedId,
                targetTabId: nil,
                tabIds: scopeIds,
                pinnedTabIds: pinnedIds
            )
        }

        // First band whose bottom edge is below the cursor is the target; this
        // also assigns the inter-row spacing gap to the lower band.
        let targetBand = bands.first(where: { cursorY < $0.maxY }) ?? lastBand
        let pointerY = cursorY - targetBand.minY

        let effectivePointerY = stickyPointerY(
            pointerY: pointerY,
            band: targetBand,
            scopeIds: scopeIds,
            current: current,
            margin: hysteresisMargin
        )

        return SidebarDropPlanner.indicator(
            draggedTabId: draggedId,
            targetTabId: targetBand.id,
            tabIds: scopeIds,
            pinnedTabIds: pinnedIds,
            pointerY: effectivePointerY,
            targetHeight: targetBand.height
        )
    }

    /// Biases `pointerY` toward the current edge while the cursor sits within
    /// `margin` of the band midpoint, so the indicator does not oscillate on
    /// sub-pixel jitter at the 50% split.
    private static func stickyPointerY(
        pointerY: CGFloat,
        band: Band,
        scopeIds: [UUID],
        current: SidebarDropIndicator?,
        margin: CGFloat
    ) -> CGFloat {
        let mid = band.height / 2
        guard margin > 0, abs(pointerY - mid) < margin else { return pointerY }
        guard let edge = currentEdge(for: band, scopeIds: scopeIds, current: current) else {
            return pointerY
        }
        return edge == .top ? mid - margin : mid + margin
    }

    /// The edge of `band` that the current indicator represents, if any. The
    /// planner canonicalizes "after row i" to "top of row i+1" (or the end
    /// sentinel), so both forms are matched here.
    private static func currentEdge(
        for band: Band,
        scopeIds: [UUID],
        current: SidebarDropIndicator?
    ) -> SidebarDropEdge? {
        guard let current else { return nil }
        if current.tabId == band.id, current.edge == .top { return .top }
        guard let index = scopeIds.firstIndex(of: band.id) else { return nil }
        let afterId: UUID? = index + 1 < scopeIds.count ? scopeIds[index + 1] : nil
        if let afterId, current.tabId == afterId, current.edge == .top { return .bottom }
        if afterId == nil, current.tabId == nil, current.edge == .bottom { return .bottom }
        return nil
    }
}
