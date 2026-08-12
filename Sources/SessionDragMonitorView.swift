import AppKit

/// Event-owning AppKit source bridge mounted behind one group of Vault rows.
@MainActor
final class SessionDragMonitorView: NSView {
    private struct PendingDrag {
        let region: SessionDragRegionStore.Region
        let mouseDownEvent: NSEvent
        let startPoint: NSPoint
    }

    var regions: SessionDragRegionStore
    var beginDrag: SessionDragBeginAction

    private var localMouseMonitor: Any?
    private var pendingDrag: PendingDrag?
    private let dragThresholdSquared: CGFloat = 16

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(
        frame frameRect: NSRect = .zero,
        regions: SessionDragRegionStore,
        beginDrag: @escaping SessionDragBeginAction
    ) {
        self.regions = regions
        self.beginDrag = beginDrag
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeLocalMouseMonitor()
        guard window != nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleEvent(event) ?? event
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    @discardableResult
    func handleEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            trackMouseDown(event)
        case .leftMouseDragged:
            beginDragIfNeeded(event)
        case .leftMouseUp:
            pendingDrag = nil
        default:
            break
        }
        return event
    }

    private func trackMouseDown(_ event: NSEvent) {
        pendingDrag = nil
        guard !event.modifierFlags.contains(.control),
              let window,
              event.windowNumber == window.windowNumber else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point),
              let region = regions.region(at: point) else {
            return
        }
        pendingDrag = PendingDrag(
            region: region,
            mouseDownEvent: event,
            startPoint: point
        )
#if DEBUG
        cmuxDebugLog(
            "vault.drag.source.mouseDown occurrence=\(region.rowID.occurrence) clicks=\(event.clickCount)"
        )
#endif
    }

    private func beginDragIfNeeded(_ event: NSEvent) {
        guard let pendingDrag,
              let window,
              event.windowNumber == window.windowNumber else {
            self.pendingDrag = nil
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let deltaX = point.x - pendingDrag.startPoint.x
        let deltaY = point.y - pendingDrag.startPoint.y
        guard (deltaX * deltaX) + (deltaY * deltaY) >= dragThresholdSquared else {
            return
        }
        self.pendingDrag = nil

        let frame = pendingDrag.region.frame.intersection(bounds)
        guard frame.width > 0, frame.height > 0 else { return }
        let image = dragImage(for: frame) ?? NSImage(size: frame.size)
        _ = beginDrag(
            pendingDrag.region.entry,
            self,
            pendingDrag.mouseDownEvent,
            frame,
            image
        )
    }

    private func dragImage(for frame: NSRect) -> NSImage? {
        guard let contentView = window?.contentView else { return nil }
        let contentFrame = convert(frame, to: contentView)
        guard let representation = contentView.bitmapImageRepForCachingDisplay(
            in: contentFrame
        ) else {
            return nil
        }
        contentView.cacheDisplay(in: contentFrame, to: representation)
        let image = NSImage(size: frame.size)
        image.addRepresentation(representation)
        return image
    }

    private func removeLocalMouseMonitor() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        pendingDrag = nil
    }
}
