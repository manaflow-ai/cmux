import AppKit

/// Retained AppKit source whose terminal callback owns native drag cleanup.
@MainActor
final class SidebarWorkspaceDragSessionSource: NSObject, NSDraggingSource {
    private let sessionId: UUID
    private weak var registry: SidebarWorkspaceDragRegistry?

    init(sessionId: UUID, registry: SidebarWorkspaceDragRegistry) {
        self.sessionId = sessionId
        self.registry = registry
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
        registry?.nativeDraggingSessionDidEnd(sessionId: sessionId)
    }
}
