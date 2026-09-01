import AppKit

/// Starts workspace drags without intercepting the sidebar row's click gestures.
@MainActor
final class SidebarWorkspaceDragSourceMonitor {
    typealias BeginDrag = @MainActor (
        _ workspaceId: UUID,
        _ sourceView: NSView,
        _ mouseDownEvent: NSEvent,
        _ draggingFrame: NSRect,
        _ dragImage: NSImage
    ) -> Bool

    private weak var hostView: NSView?
    private var eventMonitor: Any?
    private var pendingDrag: SidebarWorkspacePendingDrag?
    private var resolveCandidate: (@MainActor (CGPoint) -> SidebarWorkspaceDragCandidate?)?
    private var onBeginDrag: BeginDrag?
    private let dragThresholdSquared: CGFloat = 16

    deinit {
        // `deinit` is nonisolated under Swift 6; remove the AppKit monitor
        // directly so releasing a monitor during view reconstruction cannot
        // leave a process-wide callback behind.
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    func start(
        resolveCandidate: @escaping @MainActor (CGPoint) -> SidebarWorkspaceDragCandidate?,
        onBeginDrag: @escaping BeginDrag
    ) {
        self.resolveCandidate = resolveCandidate
        self.onBeginDrag = onBeginDrag
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        pendingDrag = nil
        resolveCandidate = nil
        onBeginDrag = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    func attach(to hostView: NSView) {
        self.hostView = hostView
    }

    func detach(from hostView: NSView) {
        guard self.hostView === hostView else { return }
        self.hostView = nil
        pendingDrag = nil
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            trackMouseDown(event)
            return event
        case .leftMouseDragged:
            return handleMouseDragged(event)
        case .leftMouseUp:
            pendingDrag = nil
            return event
        default:
            return event
        }
    }

    private func trackMouseDown(_ event: NSEvent) {
        pendingDrag = nil
        guard event.clickCount == 1,
              !event.modifierFlags.contains(.control),
              let hostView,
              let window = hostView.window,
              event.windowNumber == window.windowNumber else {
            return
        }

        let appKitPoint = hostView.convert(event.locationInWindow, from: nil)
        guard hostView.bounds.contains(appKitPoint),
              !Self.isNativeInteraction(at: event.locationInWindow, in: window) else {
            return
        }
        let swiftUIPoint = SidebarPointerInteractionMonitor.swiftUIPoint(
            fromAppKitPoint: appKitPoint,
            viewportBounds: hostView.bounds
        )
        guard let candidate = resolveCandidate?(swiftUIPoint) else { return }
        pendingDrag = SidebarWorkspacePendingDrag(
            mouseDownEvent: event,
            startPoint: appKitPoint,
            candidate: candidate
        )
    }

    private func handleMouseDragged(_ event: NSEvent) -> NSEvent? {
        guard let pendingDrag,
              let hostView,
              let window = hostView.window,
              event.windowNumber == window.windowNumber else {
            self.pendingDrag = nil
            return event
        }

        let point = hostView.convert(event.locationInWindow, from: nil)
        let deltaX = point.x - pendingDrag.startPoint.x
        let deltaY = point.y - pendingDrag.startPoint.y
        guard (deltaX * deltaX) + (deltaY * deltaY) >= dragThresholdSquared else {
            return event
        }
        self.pendingDrag = nil

        guard let representation = dragRepresentation(
            for: pendingDrag.candidate.swiftUIFrame,
            in: hostView
        ), let onBeginDrag else {
            return event
        }
        let didBegin = onBeginDrag(
            pendingDrag.candidate.workspaceId,
            hostView,
            pendingDrag.mouseDownEvent,
            representation.frame,
            representation.image
        )
        guard didBegin else {
            // A failed native start must leave the original event stream
            // untouched and must not create a coordinator session. The
            // pending candidate is already consumed, so a later mouse-up is a
            // normal click rather than a second attempt against stale state.
            return event
        }
        // The threshold-crossing move must still reach SwiftUI so its pending
        // tap/button press fails normally.
        return event
    }

    private func dragRepresentation(
        for swiftUIFrame: CGRect,
        in hostView: NSView
    ) -> (frame: NSRect, image: NSImage)? {
        let sourceFrame = Self.appKitRect(
            fromSwiftUIRect: swiftUIFrame,
            viewportBounds: hostView.bounds
        ).intersection(hostView.bounds)
        guard sourceFrame.width > 0,
              sourceFrame.height > 0,
              let contentView = hostView.window?.contentView else {
            return nil
        }

        let contentFrame = hostView.convert(sourceFrame, to: contentView)
        guard let representation = contentView.bitmapImageRepForCachingDisplay(in: contentFrame) else {
            return nil
        }
        contentView.cacheDisplay(in: contentFrame, to: representation)
        let image = NSImage(size: sourceFrame.size)
        image.addRepresentation(representation)
        return (sourceFrame, image)
    }

    nonisolated static func appKitRect(
        fromSwiftUIRect rect: CGRect,
        viewportBounds: CGRect
    ) -> CGRect {
        CGRect(
            x: viewportBounds.minX + rect.minX,
            y: viewportBounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func isNativeInteraction(
        at windowPoint: NSPoint,
        in window: NSWindow
    ) -> Bool {
        guard let contentView = window.contentView else { return false }
        let contentPoint = contentView.convert(windowPoint, from: nil)
        guard var candidate = contentView.hitTest(contentPoint) else { return false }
        while true {
            if candidate is NSTextView
                || candidate is NSControl
                || candidate is DraggableFolderNSView {
                return true
            }
            guard let parent = candidate.superview else { return false }
            candidate = parent
        }
    }
}
