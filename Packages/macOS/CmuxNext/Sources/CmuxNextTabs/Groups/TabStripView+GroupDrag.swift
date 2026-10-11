public import AppKit
import CmuxNextDesign
import QuartzCore

// Whole-group drag: chip plus members travel together inside the strip, and
// hand off to the App's drag session past the tear-off distance.
extension TabStripView {
    func beginGroupDrag(_ press: TabStripGroupState.Press) {
        let group = press.groupID
        let chipID = TabID.groupChip(group)
        guard let chip = motion[chipID], let first = displayed.firstIndex(where: { $0.groupID == group }) else { return }
        groups.holdTask?.cancel()
        let members = displayed.filter { $0.groupID == group }.map(\.id)
        let local = convert(press.start, to: tabsClip)
        let contentX = local.x + scroll.value
        groups.drag = TabStripGroupState.Drag(
            groupID: group,
            memberIDs: members,
            grabOffset: contentX - chip.x.value,
            originalTabIndex: first,
            currentTabIndex: first,
            blockX: chip.x.value,
            lastPoint: press.start,
            grabY: local.y
        )
        groups.press = nil
        groups.chips[group]?.isPressed = false
        setLifted(group, true)
        setHovered(nil)
        setHoveredChip(nil)
        hoverCards.dismiss(.action)
        installEscapeMonitor()
        updateSeparators()
    }

    func setLifted(_ group: TabGroupID, _ lifted: Bool) {
        groups.chips[group]?.isLifted = lifted
        for tab in displayed where tab.groupID == group { cells[tab.id]?.isLifted = lifted }
    }

    func updateGroupDrag(at point: CGPoint, event: NSEvent?) {
        guard var drag = groups.drag else { return }
        if let event, isPastTearOff(point) {
            handOffGroupDrag(event: event)
            return
        }
        drag.lastPoint = point
        let region = result.slots.filter { !$0.isPinned && $0.id != Self.placeholderID }
        let block = region.filter { groups.isDragged($0.id) }
        guard let first = region.first, let last = region.last, !block.isEmpty else { return }
        let blockWidth = block.reduce(0) { $0 + $1.width }
        let contentX = convert(point, to: tabsClip).x + scroll.value
        let x = min(max(contentX - drag.grabOffset, first.x), max(first.x, last.maxX - blockWidth))
        let entries = region.filter { !groups.isDragged($0.id) }
        let resolution = TabGroupDropMath.resolveGroup(entries: entries, start: first.x, draggedMinX: x)
        let index = displayed.count(where: \.isPinned) + resolution.tabIndex
        let moved = index != drag.currentTabIndex
        drag.blockX = x
        drag.currentTabIndex = index
        groups.drag = drag
        if moved {
            relayout(animated: !reduceMotion)
        } else {
            for slot in block {
                if let target = groupDragX(for: slot) { motion[slot.id]?.x.snap(to: target) }
            }
            applyFrames()
            startAnimating()
        }
    }

    /// Content x of a dragged block member: the block follows the pointer
    /// and keeps its internal layout.
    func groupDragX(for slot: TabLayoutSlot) -> CGFloat? {
        guard let drag = groups.drag, groups.isDragged(slot.id), let chip = result.slot(.groupChip(drag.groupID)) else { return nil }
        return drag.blockX + (slot.x - chip.x)
    }

    func endGroupDrag() {
        guard let drag = groups.drag else { return }
        groups.drag = nil
        removeEscapeMonitor()
        setLifted(drag.groupID, false)
        if drag.currentTabIndex != drag.originalTabIndex {
            var ids = displayed.map(\.id).filter { !drag.memberIDs.contains($0) }
            ids.insert(contentsOf: drag.memberIDs, at: min(drag.currentTabIndex, ids.count))
            orderOverride = ids
            sync(fromModel: false)
            model.send(.moveGroup(drag.groupID, to: drag.currentTabIndex))
        }
        relayout(animated: !reduceMotion)
    }

    func cancelGroupDrag() {
        guard var drag = groups.drag else { return }
        drag.currentTabIndex = drag.originalTabIndex
        groups.drag = drag
        endGroupDrag()
    }

    /// Hands the whole group to the App's drag session (new split, column,
    /// workspace, window, or another strip).
    func handOffGroupDrag(event: NSEvent) {
        guard let drag = groups.drag, let chip = groups.chips[drag.groupID], let window else { return }
        let memberCells = drag.memberIDs.compactMap { cells[$0] }
        let maxX = memberCells.map(\.frame.maxX).max() ?? chip.frame.maxX
        let frame = CGRect(x: chip.frame.minX, y: chip.frame.minY, width: maxX - chip.frame.minX, height: chip.frame.height)
        let screenFrame = window.convertToScreen(tabsClip.convert(frame, to: nil))
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        var layers: [CALayer] = []
        if let band = groups.bands[drag.groupID] { layers += [band.washLayer, band.lineLayer] }
        layers += memberCells.map(\.layer) + [chip.layer]
        let start = TabGroupDragStart(
            groupID: drag.groupID,
            tabIDs: drag.memberIDs,
            stripID: model.stripID,
            screenFrame: screenFrame,
            // The point pressed at mouse-down, not the pointer's offset now
            // (the tear-off distance away), as for a single tab.
            grabOffset: DragGrabPoint.screenOffset(of: CGPoint(x: frame.minX + drag.grabOffset, y: drag.grabY), in: frame,
                                                   flipped: tabsClip.isFlipped),
            screenPoint: pointer,
            snapshot: snapshot(of: layers, frame: frame)
        )
        groups.drag = nil
        removeEscapeMonitor()
        setLifted(drag.groupID, false)
        groups.detachedGroupID = drag.groupID
        sync(fromModel: false)
        model.send(.groupDragBegan(start))
    }

    /// Restores a group this strip handed off (drag cancelled). Its chip and
    /// members grow back into place. No-op when `id` is not the detached group.
    public func restoreDetachedGroup(_ id: TabGroupID) {
        guard groups.detachedGroupID == id else { return }
        groups.detachedGroupID = nil
        sync(fromModel: false)
    }
}
