import AppKit
import Bonsplit
import Observation

typealias SessionDragBeginAction = @MainActor (
    _ entry: SessionEntry,
    _ sourceView: NSView,
    _ event: NSEvent,
    _ frame: NSRect,
    _ image: NSImage
) -> Bool

/// Single main-actor owner for folder reorder state and native Vault drag sessions.
@MainActor
@Observable
final class SessionDragCoordinator {
    typealias StartDraggingSession = @MainActor (
        _ sourceView: NSView,
        _ item: NSDraggingItem,
        _ event: NSEvent,
        _ source: SessionDragSessionSource
    ) -> Void

    private enum SessionPhase {
        case idle
        case dragging(id: UUID, source: SessionDragSessionSource)
    }

    var draggedKey: SectionKey?

    @ObservationIgnored private let startDraggingSession: StartDraggingSession
    @ObservationIgnored private var sessionPhase: SessionPhase = .idle

    init(
        startDraggingSession: @escaping StartDraggingSession = { sourceView, item, event, source in
            sourceView.beginDraggingSession(
                with: [item],
                event: event,
                source: source
            )
        }
    ) {
        self.startDraggingSession = startDraggingSession
    }

    func beginSessionDrag(
        _ entry: SessionEntry,
        registry: SessionDragRegistry,
        tabDragTransferRegistry: TabDragTransferRegistry,
        from sourceView: NSView,
        event: NSEvent,
        frame: NSRect,
        image: NSImage
    ) -> Bool {
        guard frame.width > 0, frame.height > 0 else {
            return false
        }

        // Prepare the replacement capability before touching an existing
        // native source. A failed registration must leave the live drag and
        // its process-local registry untouched.
        let dragID = UUID()
        guard let transferRegistration = SessionDragPayload(
            entry: entry,
            dragID: dragID
        ).register(with: tabDragTransferRegistry) else {
            registry.discard(id: dragID)
            return false
        }

        if case .dragging(_, let source) = sessionPhase {
            // Reaching this new threshold-crossing event proves AppKit has
            // left the previous native drag loop, even if its source omitted
            // `endedAt`. Retire only that superseded source after the
            // replacement capability has been prepared.
            source.finishAfterNativeBoundary()
            sessionPhase = .idle
        }
        guard case .idle = sessionPhase else {
            tabDragTransferRegistry.end(transferRegistration)
            registry.discard(id: dragID)
            return false
        }
        _ = registry.register(entry, id: dragID)
        let dragPasteboard = NSPasteboard(name: .drag)
        dragPasteboard.clearContents()
        guard transferRegistration.write(to: dragPasteboard) else {
            tabDragTransferRegistry.end(transferRegistration)
            AppDelegate.shared?.liveTabDragCapabilityResolver.invalidate()
            registry.discard(id: dragID)
            return false
        }

        let source = SessionDragSessionSource(
            dragID: dragID,
            registry: registry,
            transferRegistration: transferRegistration,
            transferRegistry: tabDragTransferRegistry,
            onFinish: { [weak self] finishedID in
                self?.finishSession(id: finishedID)
            }
        )
        sessionPhase = .dragging(id: dragID, source: source)

        let item = NSDraggingItem(
            pasteboardWriter: transferRegistration.pasteboardItem
        )
        item.setDraggingFrame(frame, contents: image)
#if DEBUG
        cmuxDebugLog(
            "vault.drag.source.begin drag=\(dragID.uuidString.prefix(5)) agent=\(entry.agent.rawValue)"
        )
#endif
        startDraggingSession(sourceView, item, event, source)
        // Binding is an invariant of the coordinator, not of the default
        // starter closure. Injected starters used by tests and alternate
        // AppKit hosts must retain the exact source view as well.
        source.bind(sourceView: sourceView)
        return true
    }

    private func finishSession(id: UUID) {
        guard case .dragging(let activeID, _) = sessionPhase,
              activeID == id else { return }
        sessionPhase = .idle
    }
}
