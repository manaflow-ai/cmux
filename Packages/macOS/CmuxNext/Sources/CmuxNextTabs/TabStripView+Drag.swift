public import AppKit
import CmuxNextDesign
import QuartzCore
// In-strip drag reorder and the hand-off to the App drag session.
extension TabStripView {
    // MARK: - Drag reorder

    func beginDrag(_ press: Press) {
        guard let index = displayed.firstIndex(where: { $0.id == press.id }), let m = motion[press.id] else { return }
        let contentX = convert(press.start, to: tabsClip).x + scroll.value
        drag = Drag(
            id: press.id,
            grabOffset: contentX - m.x.value,
            originalIndex: index,
            currentIndex: index,
            isPinned: displayed[index].isPinned,
            lastPoint: press.start,
            originalGroup: displayed[index].groupID,
            targetGroup: displayed[index].groupID
        )
        self.press = nil
        setHovered(nil)
        hoverCard.hide(allowsQuickReshow: false)
        cells[press.id]?.isLifted = true
        installEscapeMonitor()
        updateSeparators()
    }

    func updateDrag(at point: CGPoint, event: NSEvent?) {
        guard var drag else { return }
        if let event, point.y < -metrics.tearOffDistance || point.y > bounds.height + metrics.tearOffDistance {
            handOffDrag(event: event)
            return
        }
        drag.lastPoint = point
        guard let width = motion[drag.id]?.width.target else { return }
        let contentX = convert(point, to: tabsClip).x + scroll.value
        let region = result.slots.filter { $0.isPinned == drag.isPinned && $0.id != Self.placeholderID }
        guard let first = region.first, let last = region.last else { return }
        let x = min(max(contentX - drag.grabOffset, first.x), last.maxX - width)
        let entries = region.filter { $0.id != drag.id }
        let index: Int
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
            group = resolution.groupID
        }
        motion[drag.id]?.x.follow(x, at: event?.timestamp ?? CACurrentMediaTime())
        let moved = index != drag.currentIndex || group != drag.targetGroup
        drag.currentIndex = index
        drag.targetGroup = group
        self.drag = drag
        if moved {
            relayout(animated: !reduceMotion)
        } else {
            applyFrames()
            startAnimating()
        }
    }

    /// Fraction of the dragged tab's width it must travel past a group's
    /// trailing edge to join or leave the group.
    static let groupJoinHysteresis: CGFloat = 0.3

    /// Scrolls an overflowing strip while a dragged tab sits in an edge fade.
    func autoscrollDuringDrag(_ dt: CGFloat) -> Bool {
        guard let point = drag?.lastPoint ?? groups.drag?.lastPoint ?? phantomPoint, result.isOverflowing else { return false }
        let local = convert(point, to: tabsClip).x
        let edge = metrics.scrollFadeWidth
        var speed: CGFloat = 0
        if local < edge { speed = -(edge - local) * 14 }
        if local > viewportWidth - edge { speed = (local - (viewportWidth - edge)) * 14 }
        guard speed != 0 else { return false }
        let target = TabScrollMath.clamp(scroll.value + speed * dt, contentWidth: result.contentWidth, viewportWidth: viewportWidth)
        guard target != scroll.value else { return false }
        scroll.snap(to: target)
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
        removeEscapeMonitor()
        cells[drag.id]?.isLifted = false
        // The release settles into the slot carrying the pointer's velocity.
        motion[drag.id]?.x.release(at: CACurrentMediaTime())
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
        self.drag = drag
        endDrag()
    }

    func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.drag != nil || self.groups.drag != nil else { return event }
            self.cancelDrag()
            return nil
        }
    }

    func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: - Hand-off to the App's drag session

    /// Dragging a tab past the tear-off distance hands it to the App's
    /// `TabDragSession` through `.dragBegan`. The strip collapses the slot and
    /// stops tracking; the session tracks the pointer itself from here.
    func handOffDrag(event: NSEvent) {
        guard let drag, let cell = cells[drag.id], let window else { return }
        let frameInWindow = tabsClip.convert(cell.frame, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow)
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let start = TabDragStart(
            tabID: drag.id,
            stripID: model.stripID,
            screenFrame: screenFrame,
            grabOffset: CGPoint(x: pointer.x - screenFrame.minX, y: pointer.y - screenFrame.minY),
            screenPoint: pointer,
            snapshot: snapshot(of: [cell.layer], frame: cell.frame)
        )
        self.drag = nil
        removeEscapeMonitor()
        cell.isLifted = false
        detachedID = drag.id
        sync(fromModel: false)
        model.send(.dragBegan(start))
    }

    /// Renders `layers` (tab or chip roots in the clip layer) into one image
    /// covering `frame` (clip coordinates), on a window-colored rounded card.
    func snapshot(of layers: [CALayer], frame: CGRect) -> TabImage? {
        let scale = window?.backingScaleFactor ?? 2
        let size = frame.size
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Layers are flipped; CoreGraphics is not.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        performWithTheme {
            context.setFillColor(Palette.windowBackground.cgColor)
        }
        let radius = metrics.cornerRadius
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: metrics.tabBackgroundInset, dy: 0), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        for layer in layers {
            context.saveGState()
            context.translateBy(x: layer.frame.minX - frame.minX, y: layer.frame.minY - frame.minY)
            layer.render(in: context)
            context.restoreGState()
        }
        return context.makeImage().map(TabImage.init)
    }

    /// Restores a tab this strip handed off (drag cancelled). It grows back
    /// into its slot. No-op when `id` is not the detached tab.
    public func restoreDetachedTab(_ id: TabID) {
        guard detachedID == id else { return }
        detachedID = nil
        sync(fromModel: false)
    }

    /// Drops a local reorder the App could not commit (the daemon rejected
    /// it) and shows the model's order again, even when that order did not
    /// change.
    public func discardPendingReorder() {
        guard orderOverride != nil else { return }
        orderOverride = nil
        sync(fromModel: false)
    }
}
