import AppKit

/// Retained AppKit source whose terminal callback owns native drag cleanup.
@MainActor
final class SidebarWorkspaceDragSessionSource: NSObject, NSDraggingSource {
    private let sessionId: UUID
    private let capabilityValue: String
    private weak var registry: SidebarWorkspaceDragRegistry?
    private var didFinish = false

    init(
        sessionId: UUID,
        capabilityValue: String,
        registry: SidebarWorkspaceDragRegistry
    ) {
        self.sessionId = sessionId
        self.capabilityValue = capabilityValue
        self.registry = registry
        super.init()
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
        finishDrag()
    }

    private func finishDrag() {
        guard !didFinish else { return }
        didFinish = true
        registry?.nativeDraggingSessionDidEnd(
            sessionId: sessionId,
            capabilityValue: capabilityValue
        )
    }
}
