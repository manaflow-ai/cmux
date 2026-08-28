import AppKit
import Bonsplit
import SwiftUI

/// Process-local capability registry for the one active Harbor drag,
/// mirroring `SessionDragRegistry`: pane-transfer payloads carry only an
/// opaque UUID, and shared pane targets resolve it here while the AppKit
/// drag source is alive.
@MainActor
final class HarborSessionDragRegistry {
    private enum State {
        case idle
        case active(id: UUID, session: HarborSession)
    }

    private var state: State = .idle

    func register(_ session: HarborSession) -> UUID {
        let id = UUID()
        // AppKit permits only one process-local drag at a time; replacing an
        // abandoned registration also invalidates its residual payload.
        state = .active(id: id, session: session)
        return id
    }

    func session(id: UUID) -> HarborSession? {
        guard case .active(let activeID, let session) = state,
              activeID == id else { return nil }
        return session
    }

    func discard(id: UUID) {
        guard session(id: id) != nil else { return }
        state = .idle
    }
}

/// Retained native source owning one Harbor drag's completion.
@MainActor
private final class HarborDragSessionSource: NSObject, NSDraggingSource {
    private var finished = false
    private let dragID: UUID
    private let registry: HarborSessionDragRegistry
    private let transferRegistration: TabDragTransferRegistration
    private let transferRegistry: TabDragTransferRegistry
    private let onFinish: @MainActor (UUID) -> Void

    init(
        dragID: UUID,
        registry: HarborSessionDragRegistry,
        transferRegistration: TabDragTransferRegistration,
        transferRegistry: TabDragTransferRegistry,
        onFinish: @escaping @MainActor (UUID) -> Void
    ) {
        self.dragID = dragID
        self.registry = registry
        self.transferRegistration = transferRegistration
        self.transferRegistry = transferRegistry
        self.onFinish = onFinish
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard !finished else { return }
        finished = true
        transferRegistry.end(transferRegistration)
        registry.discard(id: dragID)
        onFinish(dragID)
        // AppKit can retain the tab-transfer UTI after the source ends. Clear
        // only this registration's capability so a newer drag is untouched.
        transferRegistration.clearResidualCapability(from: NSPasteboard(name: .drag))
    }
}

/// Single main-actor owner for native Harbor drag sessions.
@MainActor
final class HarborDragCoordinator {
    private enum Phase {
        case idle
        case dragging(id: UUID)
    }

    private var phase: Phase = .idle
    private var activeSource: HarborDragSessionSource?

    func beginDrag(
        _ session: HarborSession,
        registry: HarborSessionDragRegistry,
        tabDragTransferRegistry: TabDragTransferRegistry,
        from sourceView: NSView,
        event: NSEvent,
        frame: NSRect,
        image: NSImage
    ) -> Bool {
        guard case .idle = phase, frame.width > 0, frame.height > 0 else {
            return false
        }
        let dragID = registry.register(session)
        guard let transferRegistration = tabDragTransferRegistry.register(TabDragTransfer(
            tab: Bonsplit.Tab(
                id: TabID(uuid: dragID),
                title: session.name,
                icon: "terminal.fill",
                kind: "terminal"
            ),
            // External source: this identity intentionally never names a live pane.
            sourcePaneId: PaneID(id: dragID)
        )) else {
            registry.discard(id: dragID)
            return false
        }
        let dragPasteboard = NSPasteboard(name: .drag)
        dragPasteboard.clearContents()
        guard transferRegistration.write(to: dragPasteboard) else {
            tabDragTransferRegistry.end(transferRegistration)
            AppDelegate.shared?.liveTabDragCapabilityResolver.invalidate()
            registry.discard(id: dragID)
            return false
        }
        let source = HarborDragSessionSource(
            dragID: dragID,
            registry: registry,
            transferRegistration: transferRegistration,
            transferRegistry: tabDragTransferRegistry,
            onFinish: { [weak self] finishedID in
                guard let self, case .dragging(let activeID) = self.phase,
                      activeID == finishedID else { return }
                self.phase = .idle
                self.activeSource = nil
            }
        )
        phase = .dragging(id: dragID)
        activeSource = source
        let item = NSDraggingItem(pasteboardWriter: transferRegistration.pasteboardItem)
        item.setDraggingFrame(frame, contents: image)
#if DEBUG
        cmuxDebugLog("harbor.drag.begin drag=\(dragID.uuidString.prefix(5)) session=\(session.id)")
#endif
        sourceView.beginDraggingSession(with: [item], event: event, source: source)
        return true
    }
}

typealias HarborDragBeginAction = @MainActor (
    _ session: HarborSession,
    _ sourceView: NSView,
    _ event: NSEvent,
    _ frame: NSRect,
    _ image: NSImage
) -> Bool

/// Places one native drag source over one rendered Harbor row.
struct HarborDragSource: NSViewRepresentable {
    let session: HarborSession
    let beginDrag: HarborDragBeginAction
    let onDoubleClick: @MainActor () -> Void

    func makeNSView(context: Context) -> HarborDragSourceView {
        HarborDragSourceView(session: session, beginDrag: beginDrag, onDoubleClick: onDoubleClick)
    }

    func updateNSView(_ nsView: HarborDragSourceView, context: Context) {
        nsView.update(session: session, beginDrag: beginDrag, onDoubleClick: onDoubleClick)
    }
}

/// Native pointer source whose bounds exactly match one rendered Harbor row.
/// Mirrors `SessionDragSourceView` (Vault); kept separate so the experiment
/// does not reshape the Vault drag path.
@MainActor
final class HarborDragSourceView: NSView {
    private struct PendingDrag {
        let session: HarborSession
        let mouseDownEvent: NSEvent
        let startPoint: NSPoint
    }

    private var session: HarborSession
    private var beginDrag: HarborDragBeginAction
    private var onDoubleClick: @MainActor () -> Void
    private var pendingDrag: PendingDrag?
    private let dragThresholdSquared: CGFloat = 16

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(
        frame frameRect: NSRect = .zero,
        session: HarborSession,
        beginDrag: @escaping HarborDragBeginAction,
        onDoubleClick: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.beginDrag = beginDrag
        self.onDoubleClick = onDoubleClick
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        session: HarborSession,
        beginDrag: @escaping HarborDragBeginAction,
        onDoubleClick: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.beginDrag = beginDrag
        self.onDoubleClick = onDoubleClick
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown:
            return event.modifierFlags.contains(.control) ? nil : self
        case .leftMouseDragged, .leftMouseUp:
            return self
        default:
            // Hover, help, and contextual-menu events remain owned by the
            // SwiftUI row underneath this transparent source view.
            return nil
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        pendingDrag = nil
        guard !event.modifierFlags.contains(.control),
              let window,
              event.windowNumber == window.windowNumber else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        pendingDrag = PendingDrag(session: session, mouseDownEvent: event, startPoint: point)
    }

    override func mouseDragged(with event: NSEvent) {
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
        let image = dragImage() ?? NSImage(size: bounds.size)
        _ = beginDrag(pendingDrag.session, self, pendingDrag.mouseDownEvent, bounds, image)
    }

    override func mouseUp(with event: NSEvent) {
        guard let pendingDrag else { return }
        self.pendingDrag = nil
        guard pendingDrag.mouseDownEvent.clickCount == 2 else { return }
        onDoubleClick()
    }

    override func cancelOperation(_ sender: Any?) {
        pendingDrag = nil
        super.cancelOperation(sender)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pendingDrag = nil
    }

    private func dragImage() -> NSImage? {
        guard let contentView = window?.contentView else { return nil }
        let contentFrame = convert(bounds, to: contentView)
        guard let representation = contentView.bitmapImageRepForCachingDisplay(in: contentFrame) else {
            return nil
        }
        contentView.cacheDisplay(in: contentFrame, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}
