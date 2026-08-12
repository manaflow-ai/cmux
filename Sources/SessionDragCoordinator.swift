import AppKit
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

    @ObservationIgnored private let registry: SessionDragRegistry
    @ObservationIgnored private let startDraggingSession: StartDraggingSession
    @ObservationIgnored private var sessionPhase: SessionPhase = .idle

    init(
        registry: SessionDragRegistry = .shared,
        startDraggingSession: @escaping StartDraggingSession = { sourceView, item, event, source in
            sourceView.beginDraggingSession(with: [item], event: event, source: source)
        }
    ) {
        self.registry = registry
        self.startDraggingSession = startDraggingSession
    }

    var hasActiveSession: Bool {
        guard case .dragging = sessionPhase else { return false }
        return true
    }

    func beginSessionDrag(
        _ entry: SessionEntry,
        from sourceView: NSView,
        event: NSEvent,
        frame: NSRect,
        image: NSImage
    ) -> Bool {
        guard case .idle = sessionPhase,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }

        let dragID = registry.register(entry)
        guard let pasteboardItem = SessionDragPayload.pasteboardItem(
            for: entry,
            dragID: dragID
        ) else {
            registry.discard(id: dragID)
            return false
        }

        let source = SessionDragSessionSource(
            dragID: dragID,
            registry: registry,
            onFinish: { [weak self] finishedID in
                self?.finishSession(id: finishedID)
            }
        )
        sessionPhase = .dragging(id: dragID, source: source)

        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(frame, contents: image)
#if DEBUG
        cmuxDebugLog(
            "vault.drag.source.begin drag=\(dragID.uuidString.prefix(5)) agent=\(entry.agent.rawValue)"
        )
#endif
        startDraggingSession(sourceView, item, event, source)
        return true
    }

    private func finishSession(id: UUID) {
        guard case .dragging(let activeID, _) = sessionPhase,
              activeID == id else { return }
        sessionPhase = .idle
    }
}
