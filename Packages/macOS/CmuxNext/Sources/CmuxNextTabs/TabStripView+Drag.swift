public import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore
// In-strip drag reorder and the hand-off to the App drag session.
extension TabStripView {
    // MARK: - Drag reorder

    func beginDrag(_ press: TabStripPress) {
        guard let start = displayed.first(where: { $0.id == press.id }), placed[press.id] != nil else { return }
        // The tab is lifted where it shows now (a move may be in flight), then follows the pointer from there.
        let shown = shownX(press.id) ?? placed[press.id]?.x ?? 0
        let local = convert(press.start, to: tabsClip)
        let contentX = scrollMapping.contentX(local.x, isPinned: start.isPinned)
        guard let index = displayed.firstIndex(where: { $0.id == press.id }) else { return }
        // Dragging one of several selected tabs takes them all (Chrome): the others hide under it.
        hideDragCompanions(of: press.id)
        placed[press.id]?.x = shown
        drag = TabStripDrag(
            id: press.id,
            grabOffset: contentX - shown,
            originalIndex: index,
            currentIndex: index,
            isPinned: displayed[index].isPinned,
            lastPoint: press.start,
            originalGroup: displayed[index].groupID,
            targetGroup: displayed[index].groupID,
            grabY: local.y,
            lastMoveX: contentX
        )
        self.press = nil
        setHovered(nil)
        hoverCards.dismiss(.action)
        cells[press.id]?.isLifted = true
        escapeMonitor.install()
        TabSeparatorVisibility.apply(to: self)
    }

    func updateDrag(at point: CGPoint, event: NSEvent?) {
        guard var drag else { return }
        if let event, isPastTearOff(point) {
            handOffDrag(event: event)
            return
        }
        drag.lastPoint = point
        guard let width = placed[drag.id]?.width else { return }
        let contentX = scrollMapping.contentX(convert(point, to: tabsClip).x, isPinned: drag.isPinned)
        let region = result.slots.filter { $0.isPinned == drag.isPinned && $0.id != Self.placeholderID }
        guard let first = region.first, let last = region.last else { return }
        let x = min(max(contentX - drag.grabOffset, first.x), last.maxX - width)
        let entries = region.filter { $0.id != drag.id }
        var index: Int
        var group: TabGroupID?
        if drag.isPinned {
            index = TabReorderMath.insertionIndex(draggedMinX: x, groupStart: first.x, otherWidths: entries.map(\.width))
        } else {
            let resolution = TabGroupDropMath.resolveTab(
                entries: entries,
                start: first.x,
                draggedMinX: x,
                currentGroup: drag.targetGroup,
                hysteresis: width * Self.groupJoinHysteresis
            )
            index = displayed.count(where: \.isPinned) + resolution.index
            // A multi-tab drag moves the tabs only; their groups stay.
            group = dragCompanions.isEmpty ? resolution.groupID : drag.targetGroup
        }
        placed[drag.id]?.x = x
        // Chrome: a reorder waits until the pointer moved 16 x width / maxWidth pt (the density's max,
        // hq-4e + cmux2-0b) since the last one, the width of the tab being passed: moving right that is
        // the tab now just left of the target index among the others, moving left the one at it.
        let others = displayed.filter { $0.id != drag.id }
        if index != drag.currentIndex, group == drag.targetGroup, !others.isEmpty {
            let passedIndex = index > drag.currentIndex ? index - 1 : index
            let passed = result.slot(others[min(max(passedIndex, 0), others.count - 1)].id)?.width ?? width
            if abs(contentX - drag.lastMoveX) <= metrics.chrome.reorderThreshold(forTabWidth: passed) { index = drag.currentIndex }
        }
        let moved = index != drag.currentIndex || group != drag.targetGroup
        if moved { drag.lastMoveX = contentX }
        drag.currentIndex = index
        drag.targetGroup = group
        self.drag = drag
        if moved {
            relayout(animated: !reduceMotion)
        } else {
            applyFrames()
        }
    }

    /// Whether `point` (strip coordinates) is the tear-off distance past
    /// the strip on any side: above or below it, or sideways past its ends,
    /// where the neighbor pane's strip in the same row begins.
    func isPastTearOff(_ point: CGPoint) -> Bool {
        let d = metrics.tearOffDistance
        return point.y < -d || point.y > bounds.height + d || point.x < -d || point.x > bounds.width + d
    }

    /// Fraction of the dragged tab's width it must travel past a group's
    /// trailing edge to join or leave the group.
    static var groupJoinHysteresis: CGFloat { TabTunables.groupJoinHysteresis.value }

    /// Scrolls an overflowing strip while a dragged tab sits in an edge fade. The leading fade is after a
    /// fixed pinned band; a pinned tab dragged in that band scrolls nothing.
    func autoscrollDuringDrag(_ dt: CGFloat) -> Bool {
        guard let point = drag?.lastPoint ?? groups.drag?.lastPoint ?? phantomPoint, result.isOverflowing else { return false }
        let band = scrollMapping.band
        if drag?.isPinned == true, band > 0 { return false }
        let local = max(convert(point, to: tabsClip).x, band)
        let edge = metrics.scrollFadeWidth
        var speed: CGFloat = 0
        let gain = TabTunables.autoscrollGain.value
        if local < band + edge { speed = -(band + edge - local) * gain }
        if local > viewportWidth - edge { speed = (local - (viewportWidth - edge)) * gain }
        guard speed != 0 else { return false }
        settleScroll()
        let target = TabScrollMath.clamp(scrollOffset + speed * dt, contentWidth: result.contentWidth, viewportWidth: viewportWidth)
        guard target != scrollOffset else { return false }
        scrollOffset = target
        if let drag {
            updateDrag(at: drag.lastPoint, event: nil)
        } else if let groupDrag = groups.drag {
            updateGroupDrag(at: groupDrag.lastPoint, event: nil)
        } else if dropPlaceholderIndex != nil {
            updatePhantomPosition(at: point)
        }
        return true
    }

    func endDrag() {
        guard let drag else { return }
        self.drag = nil
        escapeMonitor.remove()
        cells[drag.id]?.isLifted = false
        if !dragCompanions.isEmpty { return endMultiDrag(drag) }
        // The release settles into the slot on a 200 ms ease-out from where it is (Chrome): `relayout`'s tabMove.
        let regrouped = drag.targetGroup != drag.originalGroup
        // The model may have changed during the drag (tabs closed by the
        // daemon); indexes captured at the start no longer hold.
        guard displayed.contains(where: { $0.id == drag.id }) else {
            sync(fromModel: true)
            return
        }
        if drag.currentIndex != drag.originalIndex || regrouped {
            var ids = displayed.map(\.id)
            ids.removeAll { $0 == drag.id }
            ids.insert(drag.id, at: min(max(drag.currentIndex, 0), ids.count))
            orderOverride = ids
            if regrouped { groups.membershipOverride.updateValue(drag.targetGroup, forKey: drag.id) }
            sync(fromModel: false)
            if !regrouped {
                model.send(.reorder(drag.id, from: drag.originalIndex, to: drag.currentIndex))
            } else if let group = drag.targetGroup {
                model.send(.addToGroup(drag.id, group, index: drag.currentIndex))
            } else {
                model.send(.removeFromGroup(drag.id, index: drag.currentIndex))
            }
        }
        relayout(animated: !reduceMotion)
    }

    /// Escape during an in-strip drag springs the tab back to where it started.
    func cancelDrag() {
        if groups.drag != nil {
            cancelGroupDrag()
            return
        }
        guard var drag else { return }
        drag.currentIndex = drag.originalIndex
        drag.targetGroup = drag.originalGroup
        drag.cancelled = true
        self.drag = drag
        endDrag()
    }

    // MARK: - Hand-off to the App's drag session

    /// Dragging a tab past the tear-off distance hands it to the App's
    /// `TabDragSession` through `.dragBegan`. The strip collapses the slot and
    /// stops tracking; the session tracks the pointer itself from here.
    ///
    /// The grab offset is the point pressed at mouse-down, in the tab: by
    /// now the pointer is the tear-off distance past the tab (and past the
    /// strip's end after a clamped reorder), so the pointer's offset from
    /// the tab here is not where the user holds it (dogfood nxdog13).
    func handOffDrag(event: NSEvent) {
        guard let drag, let cell = cells[drag.id], let window else { return }
        let frameInWindow = tabsClip.convert(cell.frame, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow)
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let grabbed = CGPoint(x: cell.frame.minX + drag.grabOffset, y: drag.grabY)
        let image = snapshot(of: [cell.layer], frame: cell.frame)
        let start = TabDragStart(
            tabID: drag.id,
            stripID: model.stripID,
            screenFrame: screenFrame,
            grabOffset: DragGrabPoint.screenOffset(of: grabbed, in: cell.frame, flipped: tabsClip.isFlipped),
            screenPoint: pointer,
            snapshot: image.image,
            snapshotOnGlass: image.onGlass
        )
        self.drag = nil
        escapeMonitor.remove()
        cell.isLifted = false
        detachedID = drag.id
        // Only the dragged tab leaves the strip; the other selected tabs show again (multi-tab moves
        // between strips, windows and the sidebar are a follow-up).
        dragCompanions = []
        sync(fromModel: false)
        model.send(.dragBegan(start))
    }

    /// The drag image of `layers` (`TabSnapshotRenderer`), on a window-colored card only in an
    /// opaque window, and whether it was drawn for glass (no card): decided in this strip's scope,
    /// which the drag ghost must follow.
    func snapshot(of layers: [CALayer], frame: CGRect) -> (image: TabImage?, onGlass: Bool) {
        let backdrop = WindowBackdrop.dragPreview(themeScope)
        let background = performWithTheme { backdrop.dragCardFill(Palette.windowBackground)?.cgColor }
        let image = TabSnapshotRenderer(metrics: metrics, scale: window?.backingScaleFactor ?? 2, background: background).image(of: layers, frame: frame)
        return (image, backdrop.dragsOnGlass)
    }

    /// The tabs the strip shows, in order (tab conservation check DP1: once
    /// no drag is in flight this equals the model's tabs).
    public var presentedTabIDs: [TabID] { displayed.map(\.id) }

    /// Restores a tab this strip handed off (drag cancelled). It grows back
    /// into its slot. No-op when `id` is not the detached tab.
    public func restoreDetachedTab(_ id: TabID) {
        guard detachedID == id else { return }
        detachedID = nil
        sync(fromModel: false)
    }

    /// Drops a local reorder the App could not commit (the daemon rejected
    /// it) and shows the model's order and groups again, even when they did
    /// not change.
    public func discardPendingReorder() {
        guard orderOverride != nil || !groups.membershipOverride.isEmpty else { return }
        (orderOverride, multiReorderTarget) = (nil, nil)
        groups.membershipOverride = [:]
        sync(fromModel: false)
    }

    /// A committed reorder: the local order and groups end once the model
    /// shows them. The store's change can trail the command's reply; ending
    /// them before it lands shows the old order for a frame and springs the
    /// tabs back (cx-f6i7), so until then they stay, and `sync(fromModel:)`
    /// ends them when the model changes. A move the model never shows (the
    /// daemon kept the old order) ends after `reorderSettleTimeout`.
    public func settlePendingReorder() {
        guard orderOverride != nil || !groups.membershipOverride.isEmpty else { return }
        let ordered = model.orderedTabs
        let inOrder = orderOverride.map { $0 == ordered.map(\.id) } ?? true
        let grouped = groups.membershipOverride.allSatisfy { id, group in
            ordered.first { $0.id == id }.map { $0.groupID == group } ?? true
        }
        if inOrder, grouped { return discardPendingReorder() }
        let pending = (order: orderOverride, groups: groups.membershipOverride)
        reorderSettle.schedule(after: Self.reorderSettleTimeout) { @MainActor [weak self] in
            // Each part ends on its own: a sync can end the order alone (a tab torn out meanwhile).
            guard let self else { return }
            var changed = false
            if pending.order != nil, self.orderOverride == pending.order { (self.orderOverride, self.multiReorderTarget) = (nil, nil); changed = true }
            if !pending.groups.isEmpty, self.groups.membershipOverride == pending.groups { self.groups.membershipOverride = [:]; changed = true }
            if changed { self.sync(fromModel: false) }
        }
    }

    /// How long a committed reorder waits for the store's change (it
    /// trails the reply by a frame or two) before the model's order shows.
    static let reorderSettleTimeout: Duration = .milliseconds(300)
}

// Debug proofs (debug.new_tab frame_strip `drag_new`) drive a drag at a tab's place.
extension TabStripView {
    /// The tabs in the order the strip shows them.
    public var displayedOrder: [TabID] { displayed.map(\.id) }

    /// Where `id`'s cell shows now, its center in window coordinates; nil when it shows nowhere.
    public func tabCenterInWindow(_ id: TabID) -> CGPoint? {
        guard let cell = cells[id] else { return nil }
        let frame = (cell.layer.presentation() ?? cell.layer).frame
        return tabsClip.convert(CGPoint(x: frame.midX, y: tabsClip.bounds.midY), to: nil)
    }
}
