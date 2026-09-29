import AppKit

/// A minimal stand-in for the App's `TabDragSession`: a floating ghost that
/// follows the pointer, phantom gaps in whichever strip is under it, and a
/// local model move on drop. Shows how the strip's drag APIs fit together.
final class DemoDragSession {
    private let start: TabDragStart
    private let strips: [TabStripView]
    private let ghost: NSPanel
    private var monitor: Any?
    private var target: (strip: TabStripView, target: TabStripDropTarget)?
    private let finished: () -> Void

    init(start: TabDragStart, strips: [TabStripView], finished: @escaping () -> Void) {
        self.start = start
        self.strips = strips
        self.finished = finished
        ghost = NSPanel(contentRect: start.screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = true
        ghost.ignoresMouseEvents = true
        ghost.level = .floating
        let image = NSImageView()
        if let snapshot = start.snapshot {
            image.image = NSImage(cgImage: snapshot.cgImage, size: start.screenFrame.size)
        }
        image.imageScaling = .scaleAxesIndependently
        ghost.contentView = image
        ghost.alphaValue = 0.92
        ghost.orderFrontRegardless()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
        move(to: start.screenPoint)
    }

    func move(to point: CGPoint) {
        target = nil
        for strip in strips {
            if let hit = strip.updatePhantom(atScreenPoint: point), target == nil {
                target = (strip, hit)
            } else if target != nil {
                strip.hidePhantom()
            }
        }
        let size = start.screenFrame.size
        let frame = target?.target.ghostFrame
            ?? CGRect(x: point.x - start.grabOffset.x, y: point.y - start.grabOffset.y, width: size.width, height: size.height)
        ghost.setFrame(frame, display: true)
    }

    func drop() {
        defer { end() }
        guard let (strip, hit) = target, let source = strips.first(where: { $0.model.stripID == start.stripID }) else {
            cancel()
            return
        }
        let destination = strip.model
        strip.commitPhantom(tabID: start.tabID)
        if destination === source.model {
            destination.apply(.reorder(start.tabID, from: 0, to: hit.index)) { TabStripDemo.makeTab() }
            destination.selectedID = start.tabID
        } else if var item = source.model.tab(start.tabID) {
            source.model.apply(.close(start.tabID, source: .keyboard)) { TabStripDemo.makeTab() }
            item.isPinned = false
            var ordered = destination.orderedTabs
            ordered.insert(item, at: min(hit.index, ordered.count))
            destination.tabs = ordered
            destination.selectedID = item.id
        }
    }

    func cancel() {
        strips.first { $0.model.stripID == start.stripID }?.restoreDetachedTab(start.tabID)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged: move(to: NSEvent.mouseLocation)
        case .leftMouseUp: drop()
        case .keyDown where event.keyCode == 53:
            cancel()
            end()
        default: break
        }
    }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for strip in strips { strip.hidePhantom() }
        ghost.orderOut(nil)
        finished()
    }
}
