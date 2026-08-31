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
        case active(id: UUID, item: HarborDragItem)
    }

    private var state: State = .idle

    func register(_ item: HarborDragItem) -> UUID {
        let id = UUID()
        // AppKit permits only one process-local drag at a time; replacing an
        // abandoned registration also invalidates its residual payload.
        state = .active(id: id, item: item)
        return id
    }

    func item(id: UUID) -> HarborDragItem? {
        guard case .active(let activeID, let item) = state,
              activeID == id else { return nil }
        return item
    }

    func register(_ session: HarborSession) -> UUID {
        register(.legacySession(session))
    }

    func session(id: UUID) -> HarborSession? {
        guard let item = item(id: id) else { return nil }
        if case .legacySession(let session) = item { return session }
        switch item {
        case .sessionTUI(let host, let tool, let name, let state):
            return HarborSession(source: host, tool: tool, name: name, state: state, detail: "")
        case .leaf, .legacySession:
            return nil
        }
    }

    func discard(id: UUID) {
        guard item(id: id) != nil else { return }
        state = .idle
    }
}

/// Retained native source owning one Harbor drag's completion. The payload is
/// an opaque in-process capability, so a stale pasteboard cannot attach a
/// session after the registry has discarded it.
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

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard !finished else { return }
        finished = true
        transferRegistry.end(transferRegistration)
        registry.discard(id: dragID)
        onFinish(dragID)
        transferRegistration.clearResidualCapability(from: NSPasteboard(name: .drag))
    }
}

/// Single main-actor owner for native Harbor drag sessions.
@MainActor
final class HarborDragCoordinator {
    private enum Phase { case idle, dragging(id: UUID) }
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
        beginDrag(
            .legacySession(session), registry: registry,
            tabDragTransferRegistry: tabDragTransferRegistry,
            title: session.name, from: sourceView, event: event, frame: frame, image: image
        )
    }

    func beginDrag(
        _ item: HarborDragItem,
        registry: HarborSessionDragRegistry,
        tabDragTransferRegistry: TabDragTransferRegistry,
        title: String,
        from sourceView: NSView,
        event: NSEvent,
        frame: NSRect,
        image: NSImage
    ) -> Bool {
        guard case .idle = phase, frame.width > 0, frame.height > 0 else { return false }
        let dragID = registry.register(item)
        guard let registration = tabDragTransferRegistry.register(TabDragTransfer(
            tab: Bonsplit.Tab(id: TabID(uuid: dragID), title: title, icon: "terminal.fill", kind: "terminal"),
            sourcePaneId: PaneID(id: dragID)
        )) else {
            registry.discard(id: dragID)
            return false
        }
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        guard registration.write(to: pasteboard) else {
            tabDragTransferRegistry.end(registration)
            AppDelegate.shared?.liveTabDragCapabilityResolver.invalidate()
            registry.discard(id: dragID)
            return false
        }
        let source = HarborDragSessionSource(
            dragID: dragID, registry: registry, transferRegistration: registration,
            transferRegistry: tabDragTransferRegistry,
            onFinish: { [weak self] id in
                guard let self, case .dragging(let activeID) = self.phase, activeID == id else { return }
                self.phase = .idle
                self.activeSource = nil
            }
        )
        phase = .dragging(id: dragID)
        activeSource = source
        let dragItem = NSDraggingItem(pasteboardWriter: registration.pasteboardItem)
        dragItem.setDraggingFrame(frame, contents: image)
        sourceView.beginDraggingSession(with: [dragItem], event: event, source: source)
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

/// Places one native drag source over one rendered session row.
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

@MainActor
final class HarborDragSourceView: NSView {
    private struct PendingDrag {
        let session: HarborSession
        let event: NSEvent
        let point: NSPoint
    }
    private var session: HarborSession
    private var beginDrag: HarborDragBeginAction
    private var onDoubleClick: @MainActor () -> Void
    private var pending: PendingDrag?
    private let thresholdSquared: CGFloat = 16

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(frame: NSRect = .zero, session: HarborSession, beginDrag: @escaping HarborDragBeginAction, onDoubleClick: @escaping @MainActor () -> Void) {
        self.session = session
        self.beginDrag = beginDrag
        self.onDoubleClick = onDoubleClick
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(session: HarborSession, beginDrag: @escaping HarborDragBeginAction, onDoubleClick: @escaping @MainActor () -> Void) {
        self.session = session
        self.beginDrag = beginDrag
        self.onDoubleClick = onDoubleClick
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown: return event.modifierFlags.contains(.control) ? nil : self
        case .leftMouseDragged, .leftMouseUp: return self
        default: return nil
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pending = nil
        guard !event.modifierFlags.contains(.control), let window, event.windowNumber == window.windowNumber else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        pending = PendingDrag(session: session, event: event, point: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pending, let window, event.windowNumber == window.windowNumber else { self.pending = nil; return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - pending.point.x
        let dy = point.y - pending.point.y
        guard dx * dx + dy * dy >= thresholdSquared else { return }
        self.pending = nil
        _ = beginDrag(pending.session, self, pending.event, bounds, dragImage() ?? NSImage(size: bounds.size))
    }

    override func mouseUp(with event: NSEvent) {
        guard let pending else { return }
        self.pending = nil
        if pending.event.clickCount == 2 { onDoubleClick() }
    }

    override func cancelOperation(_ sender: Any?) { pending = nil; super.cancelOperation(sender) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); pending = nil }

    private func dragImage() -> NSImage? {
        guard let contentView = window?.contentView else { return nil }
        let frame = convert(bounds, to: contentView)
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: frame) else { return nil }
        contentView.cacheDisplay(in: frame, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
