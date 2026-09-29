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
            lastPoint: press.start
        )
        self.press = nil
        setHovered(nil)
        hoverCard.hide(allowsQuickReshow: false)
        tabViews[press.id]?.isLifted = true
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
        let group = result.slots.filter { $0.isPinned == drag.isPinned && $0.id != Self.placeholderID }
        guard let first = group.first, let last = group.last, let width = motion[drag.id]?.width.target else { return }
        let contentX = convert(point, to: tabsClip).x + scroll.value
        let x = min(max(contentX - drag.grabOffset, first.x), last.maxX - width)
        let others = group.filter { $0.id != drag.id }.map(\.width)
        let groupIndex = TabReorderMath.insertionIndex(draggedMinX: x, groupStart: first.x, otherWidths: others)
        let index = (drag.isPinned ? 0 : displayed.count(where: \.isPinned)) + groupIndex
        motion[drag.id]?.x.snap(to: x)
        let moved = index != drag.currentIndex
        drag.currentIndex = index
        self.drag = drag
        if moved {
            relayout(animated: !reduceMotion)
        } else {
            applyFrames()
            startAnimating()
        }
    }

    /// Scrolls an overflowing strip while a dragged tab sits in an edge fade.
    func autoscrollDuringDrag(_ dt: CGFloat) -> Bool {
        guard let point = drag?.lastPoint ?? phantomPoint, result.isOverflowing else { return false }
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
        } else if dropPlaceholderIndex != nil {
            let index = phantomIndex(at: point)
            if index != dropPlaceholderIndex {
                dropPlaceholderIndex = index
                relayout(animated: !reduceMotion)
            }
        }
        return true
    }

    func endDrag() {
        guard let drag else { return }
        self.drag = nil
        removeEscapeMonitor()
        tabViews[drag.id]?.isLifted = false
        if drag.currentIndex != drag.originalIndex {
            var ids = displayed.map(\.id)
            ids.remove(at: drag.originalIndex)
            ids.insert(drag.id, at: min(drag.currentIndex, ids.count))
            orderOverride = ids
            let byID = Dictionary(uniqueKeysWithValues: displayed.map { ($0.id, $0) })
            displayed = ids.compactMap { byID[$0] }
            model.send(.reorder(drag.id, from: drag.originalIndex, to: drag.currentIndex))
        }
        relayout(animated: !reduceMotion)
    }


    /// Escape during an in-strip drag springs the tab back to where it started.
    func cancelDrag() {
        guard var drag else { return }
        drag.currentIndex = drag.originalIndex
        self.drag = drag
        endDrag()
    }

    func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.drag != nil else { return event }
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
        guard let drag, let view = tabViews[drag.id], let window else { return }
        let frameInWindow = view.convert(view.bounds, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow)
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let start = TabDragStart(
            tabID: drag.id,
            stripID: model.stripID,
            screenFrame: screenFrame,
            grabOffset: CGPoint(x: pointer.x - screenFrame.minX, y: pointer.y - screenFrame.minY),
            screenPoint: pointer,
            snapshot: snapshot(of: view)
        )
        self.drag = nil
        removeEscapeMonitor()
        view.isLifted = false
        detachedID = drag.id
        sync(fromModel: false)
        model.send(.dragBegan(start))
    }

    func snapshot(of view: TabView) -> TabImage? {
        guard let layer = view.layer else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Layers are flipped; CoreGraphics is not.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(Palette.windowBackground.cgColor)
        }
        let radius = metrics.cornerRadius
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: metrics.tabBackgroundInset, dy: 0), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        layer.render(in: context)
        return context.makeImage().map(TabImage.init)
    }

    /// Restores a tab this strip handed off (drag cancelled). It grows back
    /// into its slot. No-op when `id` is not the detached tab.
    public func restoreDetachedTab(_ id: TabID) {
        guard detachedID == id else { return }
        detachedID = nil
        sync(fromModel: false)
    }
}
