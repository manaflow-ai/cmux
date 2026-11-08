import AppKit

/// Retained AppKit source whose terminal callback owns native drag cleanup.
@MainActor
final class SidebarWorkspaceDragSessionSource: NSObject, NSDraggingSource {
    private let sessionId: UUID
    private let capabilityValue: String
    private weak var registry: SidebarWorkspaceDragRegistry?
    private var didFinish = false
    private var sourceView: NSView?

    var sessionIdentifier: UUID { sessionId }

    deinit {}

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

    /// Retains the source view until AppKit delivers this source's `endedAt` callback.
    func bind(sourceView: NSView) {
        guard !didFinish else { return }
        self.sourceView = sourceView
    }

    /// Completes this source after a later native pointer boundary proves that
    /// AppKit has left the older drag loop, even if `endedAt` was omitted.
    func finishAfterNativeBoundary() {
        finishDrag()
    }

    private func finishDrag() {
        guard !didFinish else { return }
        didFinish = true
        registry?.nativeDraggingSessionDidEnd(
            sessionId: sessionId,
            capabilityValue: capabilityValue
        )
        sourceView = nil
    }
}
