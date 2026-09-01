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
    private var sourceView: NSOutlineView?
    private var coordinator: CloudTreeOutlineView.Coordinator?

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
        materializeRegistrationPayload()
    }

    @available(*, unavailable)
    required init(
        pasteboardPropertyList _: Any,
        ofType _: NSPasteboard.PasteboardType
    ) {
        fatalError("init(pasteboardPropertyList:ofType:) is not supported")
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

    /// Copies the registration into ``NSPasteboardItem`` storage before AppKit
    /// binds this item to a drag pasteboard. AppKit may use an item directly
    /// (without asking the ``NSPasteboardWriting`` accessors), so keeping the
    /// concrete item populated is required for both code paths.
    private func materializeRegistrationPayload() {
        let item = registration.pasteboardItem
        for type in item.types {
            if let string = item.string(forType: type) {
                _ = setString(string, forType: type)
            } else if let data = item.data(forType: type) {
                _ = setData(data, forType: type)
            } else if let propertyList = item.propertyList(forType: type) {
                _ = setPropertyList(propertyList, forType: type)
            }
        }
    }

    /// The exact outline source that requested this writer.
    var sourceViewForDrag: NSOutlineView? { sourceView }

    /// Releases the source graph after this writer's native session terminates.
    func releaseSourceGraph() {
        sourceView = nil
        coordinator = nil
    }
}
