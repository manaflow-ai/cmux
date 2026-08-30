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
    let provisionalToken: ProvisionalDragWriterOwnership.Token
    let dragID: UUID
    let registration: TabDragTransferRegistration
    private let sourceView: NSOutlineView
    private let coordinator: CloudTreeOutlineView.Coordinator

    init(
        dragID: UUID,
        registration: TabDragTransferRegistration,
        sourceView: NSOutlineView,
        coordinator: CloudTreeOutlineView.Coordinator,
        provisionalToken: ProvisionalDragWriterOwnership.Token
    ) {
        self.dragID = dragID
        self.registration = registration
        self.sourceView = sourceView
        self.coordinator = coordinator
        self.provisionalToken = provisionalToken
        super.init()
    }

    @available(*, unavailable)
    required init(
        pasteboardPropertyList _: Any,
        ofType _: NSPasteboard.PasteboardType
    ) {
        fatalError("init(pasteboardPropertyList:ofType:) is not supported")
    }

    deinit {
        provisionalToken.notifyDeallocated()
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        _ = pasteboard
        return registration.pasteboardItem.types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        // `TabDragTransferRegistration` stores its capability as a raw string
        // and the surface record as raw JSON bytes. `propertyList(forType:)`
        // only reads values written with `setPropertyList`, so proxy each
        // representation through the matching accessor before falling back to
        // a true property-list value.
        registration.pasteboardItem.string(forType: type)
            ?? registration.pasteboardItem.data(forType: type)
            ?? registration.pasteboardItem.propertyList(forType: type)
    }

    /// The exact outline source that requested this writer.
    var sourceViewForDrag: NSOutlineView { sourceView }
}
