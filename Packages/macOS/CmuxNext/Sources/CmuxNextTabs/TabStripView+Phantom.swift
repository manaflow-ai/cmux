public import AppKit
import CmuxNextDesign
import QuartzCore
// Phantom gap: the space an external drag (a tab or a whole group) opens,
// and its hit test.
extension TabStripView {
    // MARK: - Tabs

    /// Where a dragged tab would land if dropped at `screenPoint`, or nil
    /// when the point is not over this strip. Pure query: opens no gap.
    ///
    /// `index` is a position in `model.orderedTabs` without the tab this strip
    /// handed off (if any), which is the final index for a move command.
    /// `groupID` is the group the tab would join. `ghostFrame` is the screen
    /// frame of the inline slot, for the session's ghost to collapse into.
    public func dropTarget(atScreenPoint screenPoint: CGPoint, verticalSlop: CGFloat? = nil) -> TabStripDropTarget? {
        target(atScreenPoint: screenPoint, verticalSlop: verticalSlop, groupWidth: nil)
    }

    /// Opens (or moves) a spring-animated gap for an external tab drag at
    /// `screenPoint` and returns the target. Closes the gap and returns nil
    /// when the point is not over this strip. Call on every pointer move.
    @discardableResult
    public func updatePhantom(atScreenPoint screenPoint: CGPoint) -> TabStripDropTarget? {
        showPhantom(atScreenPoint: screenPoint, groupWidth: nil)
    }

    /// Call when the session commits a tab drop on this strip, before or
    /// right after sending the move command. The arriving tab takes over the
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
            groups.membershipOverride.updateValue(dropPlaceholderGroup, forKey: tabID)
        }
        sync(fromModel: false)
    }

    // MARK: - Groups

    /// Like `dropTarget`, for a whole group `width` points wide. The index
    /// is the final index of the group's first tab for a move command; it is
    /// always between groups, never inside one.
    public func groupDropTarget(atScreenPoint screenPoint: CGPoint, width: CGFloat) -> TabStripDropTarget? {
        target(atScreenPoint: screenPoint, verticalSlop: nil, groupWidth: width)
    }

    /// Opens (or moves) a group-sized gap for an external group drag.
    @discardableResult
    public func updateGroupPhantom(atScreenPoint screenPoint: CGPoint, width: CGFloat) -> TabStripDropTarget? {
        showPhantom(atScreenPoint: screenPoint, groupWidth: width)
    }

    /// Call when the session commits a group drop on this strip. A group
    /// this strip handed off reappears at the drop index at once.
    public func commitGroupPhantom(groupID: TabGroupID) {
        phantomPoint = nil
        guard let index = dropPlaceholderIndex else { return }
        if groups.detachedGroupID == groupID {
            groups.detachedGroupID = nil
            let members = model.orderedTabs.filter { $0.groupID == groupID }.map(\.id)
            var ids = displayed.map(\.id)
            ids.insert(contentsOf: members, at: min(index, ids.count))
            orderOverride = ids
        }
        dropPlaceholderIndex = nil
        dropPlaceholderGroup = nil
        groups.phantomWidth = nil
        sync(fromModel: false)
    }

    /// Closes the phantom gap with springs (the drag left or was cancelled).
    public func hidePhantom() {
        phantomPoint = nil
        guard dropPlaceholderIndex != nil, pendingDrop == nil else { return }
        dropPlaceholderIndex = nil
        dropPlaceholderGroup = nil
        groups.phantomWidth = nil
        relayout(animated: !reduceMotion)
    }

    // MARK: - Shared

    func showPhantom(atScreenPoint screenPoint: CGPoint, groupWidth: CGFloat?) -> TabStripDropTarget? {
        guard let target = target(atScreenPoint: screenPoint, verticalSlop: nil, groupWidth: groupWidth) else {
            hidePhantom()
            return nil
        }
        if let window { phantomPoint = convert(window.convertPoint(fromScreen: screenPoint), from: nil) }
        setHovered(nil)
        setHoveredChip(nil)
        hoverCards.dismiss(.action)
        if target.index != dropPlaceholderIndex || target.groupID != dropPlaceholderGroup || groupWidth != groups.phantomWidth {
            dropPlaceholderIndex = target.index
            dropPlaceholderGroup = target.groupID
            groups.phantomWidth = groupWidth
            relayout(animated: !reduceMotion)
        }
        return target
    }

    /// Autoscroll moved content under a still pointer: recompute the gap.
    func updatePhantomPosition(at point: CGPoint) {
        let resolved = resolvePhantom(at: point, groupWidth: groups.phantomWidth)
        if resolved.index != dropPlaceholderIndex || resolved.groupID != dropPlaceholderGroup {
            dropPlaceholderIndex = resolved.index
            dropPlaceholderGroup = resolved.groupID
            relayout(animated: !reduceMotion)
        }
    }

    func target(atScreenPoint screenPoint: CGPoint, verticalSlop: CGFloat?, groupWidth: CGFloat?) -> TabStripDropTarget? {
        let verticalSlop = verticalSlop ?? Metrics.space4
        guard let window, !isHiddenOrHasHiddenAncestor else { return nil }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard point.x >= 0, point.x <= bounds.width, point.y >= -verticalSlop, point.y <= bounds.height + verticalSlop else {
            return nil
        }
        let resolved = resolvePhantom(at: point, groupWidth: groupWidth)
        var items = baseLayoutItems()
        let placeholder = TabLayoutItem(id: Self.placeholderID, groupID: resolved.groupID, fixedWidth: groupWidth)
        Self.insertPlaceholder(placeholder, atTabIndex: resolved.index, into: &items)
        let layout = TabLayoutEngine.layout(items: items, availableWidth: viewportWidth, style: model.style, metrics: metrics)
        guard let slot = layout.slot(Self.placeholderID) else { return nil }
        let offset = TabScrollMath.clamp(scroll.target, contentWidth: layout.contentWidth, viewportWidth: viewportWidth)
        let local = CGRect(x: slot.x - offset, y: tabTop, width: slot.width, height: min(metrics.tabHeight, bounds.height))
        let frameInWindow = tabsClip.convert(local, to: nil)
        return TabStripDropTarget(
            stripID: model.stripID,
            index: resolved.index,
            ghostFrame: window.convertToScreen(frameInWindow),
            groupID: resolved.groupID
        )
    }

    /// Layout items of the displayed tabs, without drags or gaps.
    func baseLayoutItems() -> [TabLayoutItem] {
        TabGroupOrdering.layoutItems(displayed, groups: groups.byID, selectedID: model.selectedID, chipWidths: groups.chipWidths())
    }

    /// Index (in `displayed`) and group for a gap at `point`. Tabs resolve
    /// group membership with hysteresis; groups only land between units.
    func resolvePhantom(at point: CGPoint, groupWidth: CGFloat?) -> TabGroupDropResolution {
        let base = TabLayoutEngine.layout(items: baseLayoutItems(), availableWidth: viewportWidth, style: model.style, metrics: metrics)
        let pinnedCount = displayed.count(where: \.isPinned)
        let entries = base.slots.filter { !$0.isPinned }
        let start = entries.first?.x ?? (base.contentWidth + (pinnedCount > 0 ? metrics.pinnedGroupGap : 0))
        let width = groupWidth ?? (base.standardWidth > 0 ? base.standardWidth : metrics.maxTabWidth)
        let contentX = convert(point, to: tabsClip).x + scroll.value
        let minX = contentX - width / 2
        if groupWidth != nil {
            let resolved = TabGroupDropMath.resolveGroup(entries: entries, start: start, draggedMinX: minX)
            return TabGroupDropResolution(index: pinnedCount + resolved.tabIndex, groupID: nil)
        }
        let resolved = TabGroupDropMath.resolveTab(
            entries: entries,
            start: start,
            draggedMinX: minX,
            currentGroup: dropPlaceholderGroup,
            hysteresis: width * Self.groupJoinHysteresis
        )
        return TabGroupDropResolution(index: pinnedCount + resolved.index, groupID: resolved.groupID)
    }
}
