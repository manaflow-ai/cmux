import AppKit
import CmuxNextDesign

/// A minimal stand-in for the App's `TabDragSession`: a floating ghost that
/// follows the pointer, drop targets asked through `TabDropTargetProviding`,
/// and a local model move on drop. Handles single tabs and whole groups.
final class DemoDragSession {
    enum Source {
        case tab(TabDragStart)
        case group(TabGroupDragStart)
    }

    private let source: Source
    private let strips: [TabStripView]
    private let ghost: NSPanel
    private var monitor: Any?
    private var target: (strip: TabStripView, proposal: TabDropProposal)?
    private let finished: () -> Void

    private var stripID: UUID {
        switch source {
        case .tab(let start): start.stripID
        case .group(let start): start.stripID
        }
    }

    private var frame: CGRect {
        switch source {
        case .tab(let start): start.screenFrame
        case .group(let start): start.screenFrame
        }
    }

    private var grabOffset: CGPoint {
        switch source {
        case .tab(let start): start.grabOffset
        case .group(let start): start.grabOffset
        }
    }

    private var payload: TabDragPayload {
        switch source {
        case .tab(let start): .tab(id: start.tabID.rawValue, sourceStripID: start.stripID)
        case .group(let start):
            .tabGroup(id: start.groupID.rawValue, tabIDs: start.tabIDs.map(\.rawValue), sourceStripID: start.stripID, width: start.screenFrame.width)
        }
    }

    init(source: Source, strips: [TabStripView], finished: @escaping () -> Void) {
        self.source = source
        self.strips = strips
        self.finished = finished
        let start: (CGRect, TabImage?, CGPoint) = switch source {
        case .tab(let s): (s.screenFrame, s.snapshot, s.screenPoint)
        case .group(let s): (s.screenFrame, s.snapshot, s.screenPoint)
        }
        ghost = NSPanel(contentRect: start.0, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = true
        ghost.ignoresMouseEvents = true
        ghost.level = .floating
        let image = NSImageView()
        if let snapshot = start.1 { image.image = NSImage(cgImage: snapshot.cgImage, size: start.0.size) }
        image.imageScaling = .scaleAxesIndependently
        ghost.contentView = image
        ghost.alphaValue = 0.92
        ghost.orderFrontRegardless()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
        move(to: start.2)
    }

    func move(to point: CGPoint) {
        let previous = target?.strip
        target = nil
        for strip in strips {
            if target == nil, let proposal = strip.dropHitTest(screenPoint: point, payload: payload) {
                target = (strip, proposal)
            } else if strip === previous {
                strip.dropExited()
            }
        }
        let size = frame.size
        var ghostFrame = CGRect(x: point.x - grabOffset.x, y: point.y - grabOffset.y, width: size.width, height: size.height)
        if case .tab = source, let inline = target?.proposal.ghostFrame { ghostFrame = inline }
        ghost.setFrame(ghostFrame, display: true)
    }

    func drop() {
        defer { end() }
        guard let (strip, proposal) = target, case .strip(_, let index, let group) = proposal.kind,
              let origin = strips.first(where: { $0.model.stripID == stripID })
        else {
            cancel()
            return
        }
        let destination = strip.model
        let groupID = group.map { TabGroupID($0) }
        switch source {
        case .tab(let start):
            strip.dropEnded(committed: proposal)
            if destination === origin.model {
                let intent: TabStripIntent = groupID.map { .addToGroup(start.tabID, $0, index: index) }
                    ?? .removeFromGroup(start.tabID, index: index)
                if !destination.apply(intent, makeTab: { TabStripDemo.makeTab() }) {
                    destination.apply(.reorder(start.tabID, from: 0, to: index)) { TabStripDemo.makeTab() }
                }
                destination.selectedID = start.tabID
            } else if var item = origin.model.tab(start.tabID) {
                origin.model.apply(.close(start.tabID, source: .keyboard)) { TabStripDemo.makeTab() }
                item.isPinned = false
                item.groupID = groupID
                var ordered = destination.orderedTabs
                ordered.insert(item, at: min(index, ordered.count))
                destination.tabs = ordered
                destination.selectedID = item.id
            }
        case .group(let start):
            strip.dropEnded(committed: proposal)
            if destination === origin.model {
                destination.apply(.moveGroup(start.groupID, to: index)) { TabStripDemo.makeTab() }
            } else if let item = origin.model.group(start.groupID) {
                let members = origin.model.members(of: start.groupID)
                origin.model.apply(.group(.close(start.groupID))) { TabStripDemo.makeTab() }
                var ordered = destination.orderedTabs
                ordered.insert(contentsOf: members, at: min(index, ordered.count))
                destination.groups.append(item)
                destination.tabs = ordered
            }
        }
        for other in strips where other !== strip { other.dropEnded(committed: nil) }
    }

    func cancel() {
        for strip in strips { strip.dropEnded(committed: nil) }
        let origin = strips.first { $0.model.stripID == stripID }
        switch source {
        case .tab(let start): origin?.restoreDetachedTab(start.tabID)
        case .group(let start): origin?.restoreDetachedGroup(start.groupID)
        }
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
        ghost.orderOut(nil)
        finished()
    }
}
