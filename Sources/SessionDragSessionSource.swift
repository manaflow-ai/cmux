import AppKit
import Bonsplit

/// Retained native source whose terminal callback owns Vault drag completion.
@MainActor
final class SessionDragSessionSource: NSObject, NSDraggingSource {
    private enum Phase {
        case active
        case finished
    }

    let dragID: UUID
    private let registry: SessionDragRegistry
    private let transferRegistration: TabDragTransferRegistration
    private let transferRegistry: TabDragTransferRegistry
    private let onFinish: @MainActor (UUID) -> Void
    private var phase: Phase = .active

    init(
        dragID: UUID,
        registry: SessionDragRegistry,
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
#if DEBUG
        cmuxDebugLog(
            "vault.drag.source.end drag=\(dragID.uuidString.prefix(5)) operation=\(operation.rawValue)"
        )
#endif
        finishDrag()
        // Residual transfer types on the system drag pasteboard keep
        // drop-capture hit-testing armed after the session ends.
        transferRegistration.clearResidualCapability(from: NSPasteboard(name: .drag))
    }

    func finishDrag() {
        guard case .active = phase else { return }
        phase = .finished
        transferRegistry.end(transferRegistration)
        registry.discard(id: dragID)
        onFinish(dragID)
    }
}
