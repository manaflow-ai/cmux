public import AppKit
import CmuxNextDesign
import QuartzCore
// Phantom tab: the gap an external drag opens, and its hit test.
extension TabStripView {
    // MARK: - Phantom tab for external drags

    /// Where a dragged tab would land if dropped at `screenPoint`, or nil
    /// when the point is not over this strip. Pure query: opens no gap.
    ///
    /// `index` is a position in `model.orderedTabs` without the tab this strip
    /// handed off (if any), which is the final index for a move command.
    /// `ghostFrame` is the screen frame of the inline slot, for the session's
    /// ghost to collapse into.
    public func dropTarget(atScreenPoint screenPoint: CGPoint, verticalSlop: CGFloat? = nil) -> TabStripDropTarget? {
        let verticalSlop = verticalSlop ?? Metrics.space4
        guard let window, !isHiddenOrHasHiddenAncestor else { return nil }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard point.x >= 0, point.x <= bounds.width, point.y >= -verticalSlop, point.y <= bounds.height + verticalSlop else {
            return nil
        }
        let index = phantomIndex(at: point)
        var items = displayed.map { TabLayoutItem(id: $0.id, isPinned: $0.isPinned, isSelected: $0.id == model.selectedID) }
        items.insert(TabLayoutItem(id: Self.placeholderID), at: min(index, items.count))
        let layout = TabLayoutEngine.layout(items: items, availableWidth: viewportWidth, style: model.style, metrics: metrics)
        guard let slot = layout.slot(Self.placeholderID) else { return nil }
        let offset = TabScrollMath.clamp(scroll.target, contentWidth: layout.contentWidth, viewportWidth: viewportWidth)
        let local = CGRect(
            x: slot.x - offset,
            y: tabTop,
            width: slot.width,
            height: min(metrics.tabHeight, bounds.height)
        )
        let frameInWindow = tabsClip.convert(local, to: nil)
        return TabStripDropTarget(stripID: model.stripID, index: index, ghostFrame: window.convertToScreen(frameInWindow))
    }

    /// Opens (or moves) a spring-animated gap for an external drag at
    /// `screenPoint` and returns the target. Closes the gap and returns nil
    /// when the point is not over this strip. Call on every pointer move.
    @discardableResult
    public func updatePhantom(atScreenPoint screenPoint: CGPoint) -> TabStripDropTarget? {
        guard let target = dropTarget(atScreenPoint: screenPoint) else {
            hidePhantom()
            return nil
        }
        if let window { phantomPoint = convert(window.convertPoint(fromScreen: screenPoint), from: nil) }
        setHovered(nil)
        hoverCard.hide(allowsQuickReshow: false)
        if target.index != dropPlaceholderIndex {
            dropPlaceholderIndex = target.index
            relayout(animated: !reduceMotion)
        }
        return target
    }

    /// Closes the phantom gap with springs (the drag left or was cancelled).
    public func hidePhantom() {
        phantomPoint = nil
        guard dropPlaceholderIndex != nil, pendingDrop == nil else { return }
        dropPlaceholderIndex = nil
        relayout(animated: !reduceMotion)
    }

    /// Call when the session commits a drop on this strip, before or right
    /// after sending the move command. The arriving tab takes over the
    /// phantom's geometry instead of growing in, and a tab this strip handed
    /// off reappears at the drop index at once (optimistic reorder).
    public func commitPhantom(tabID: TabID) {
        phantomPoint = nil
        guard let index = dropPlaceholderIndex, let slot = result.slot(Self.placeholderID) else { return }
        pendingDrop = (tabID, slot.x, slot.width)
        if detachedID == tabID {
            detachedID = nil
            var ids = displayed.map(\.id)
            ids.insert(tabID, at: min(index, ids.count))
            orderOverride = ids
        }
        sync(fromModel: false)
    }

    func phantomIndex(at point: CGPoint) -> Int {
        let base = TabLayoutEngine.layout(
            items: displayed.map { TabLayoutItem(id: $0.id, isPinned: $0.isPinned, isSelected: $0.id == model.selectedID) },
            availableWidth: viewportWidth,
            style: model.style,
            metrics: metrics
        )
        let pinnedCount = displayed.count(where: \.isPinned)
        let unpinned = base.slots.filter { !$0.isPinned }
        let groupStart = unpinned.first?.x ?? (base.contentWidth + (pinnedCount > 0 ? metrics.pinnedGroupGap : 0))
        let width = base.standardWidth > 0 ? base.standardWidth : metrics.maxTabWidth
        let contentX = convert(point, to: tabsClip).x + scroll.value
        return pinnedCount + TabReorderMath.insertionIndex(
            draggedMinX: contentX - width / 2,
            groupStart: groupStart,
            otherWidths: unpinned.map(\.width)
        )
    }
}
