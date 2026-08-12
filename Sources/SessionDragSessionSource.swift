import AppKit

/// Retained native source whose terminal callback owns Vault drag completion.
@MainActor
final class SessionDragSessionSource: NSObject, NSDraggingSource {
    private enum Phase {
        case active
        case finished
    }

    let dragID: UUID
    private let registry: SessionDragRegistry
    private let onFinish: @MainActor (UUID) -> Void
    private var phase: Phase = .active

    init(
        dragID: UUID,
        registry: SessionDragRegistry,
        onFinish: @escaping @MainActor (UUID) -> Void
    ) {
        self.dragID = dragID
        self.registry = registry
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
#if DEBUG
        cmuxDebugLog(
            "vault.drag.source.end drag=\(dragID.uuidString.prefix(5)) operation=\(operation.rawValue)"
        )
#endif
        finishDrag()
    }

    func finishDrag() {
        guard case .active = phase else { return }
        phase = .finished
        registry.discard(id: dragID)
        onFinish(dragID)
    }
}
