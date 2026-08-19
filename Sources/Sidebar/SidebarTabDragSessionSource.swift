import AppKit

/// Retained AppKit drag source for sidebar tab/group reorder drags.
///
/// Owning the source in AppKit (instead of SwiftUI `.onDrag`) guarantees the
/// `draggingSession(_:endedAt:operation:)` conclusion callback fires when the
/// session ends. A SwiftUI `.onDrag` session can never be concluded by the app,
/// which left the WindowServer believing a drag was still in progress and
/// suspended system-wide gestures (four-finger Mission Control) until the
/// process exited.
@MainActor
final class SidebarTabDragSessionSource: NSObject, NSDraggingSource {
    private enum Phase {
        case active
        case finished
    }

    private var phase: Phase = .active
    private let onFinish: @MainActor () -> Void

    /// Creates a source whose `onFinish` runs once, when the session concludes.
    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    /// Internal-only reorder: a tab/group drag is meaningless outside the app,
    /// so Finder must see no operation. This replaces the macOS 26
    /// `dragConfiguration` gate for the converted rows.
    static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// `NSDraggingSource` required callback: reports the operations this
    /// source allows for the given drop context.
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        Self.operationMask(for: context)
    }

    /// `NSDraggingSource` conclusion callback — the one AppKit guarantees to
    /// invoke when the session ends, which is what restores system-wide
    /// gestures after the drag.
    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        finish()
    }

    /// Idempotent conclusion: only the first invocation runs `onFinish`, so a
    /// redundant delegate callback (or a failsafe clear racing the session end)
    /// can never post a second clear.
    func finish() {
        guard case .active = phase else { return }
        phase = .finished
        onFinish()
    }
}
