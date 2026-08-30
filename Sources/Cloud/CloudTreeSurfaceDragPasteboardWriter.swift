import AppKit
import Bonsplit
import Foundation

/// Provisional pasteboard item that keeps a Cloud-tree drag source alive until
/// AppKit either promotes it to a native session or releases it as abandoned.
///
/// `NSOutlineView` asks for this item before it calls `willBeginAt`. The item
/// therefore owns the source view and coordinator during that pre-session
/// interval, while the coordinator remains the sole owner of terminal cleanup
/// after promotion to a real `NSDraggingSession`.
@MainActor
final class CloudTreeSurfaceDragPasteboardWriter: NSPasteboardItem {
    nonisolated static let didDeallocateNotification = Notification.Name(
        "cmux.cloudTreeSurfaceDragPasteboardWriterDidDeallocate"
    )
    nonisolated static let deallocationTokenKey = "token"

    let provisionalToken = UUID()
    let dragID: UUID
    let registration: TabDragTransferRegistration
    private let sourceView: NSOutlineView
    private let coordinator: CloudTreeOutlineView.Coordinator

    init(
        dragID: UUID,
        registration: TabDragTransferRegistration,
        sourceView: NSOutlineView,
        coordinator: CloudTreeOutlineView.Coordinator
    ) {
        self.dragID = dragID
        self.registration = registration
        self.sourceView = sourceView
        self.coordinator = coordinator
        super.init()
    }

    deinit {
        // Deallocation is the only terminal signal available when AppKit
        // abandons a writer before creating a native session.
        NotificationCenter.default.post(
            name: Self.didDeallocateNotification,
            object: nil,
            userInfo: [Self.deallocationTokenKey: provisionalToken]
        )
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        _ = pasteboard
        return registration.pasteboardItem.types ?? []
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        registration.pasteboardItem.propertyList(forType: type)
    }

    /// The exact outline source that requested this writer.
    var sourceViewForDrag: NSOutlineView { sourceView }

    /// The coordinator retained across SwiftUI/outline reconstruction.
    var coordinatorForDrag: CloudTreeOutlineView.Coordinator { coordinator }
}
