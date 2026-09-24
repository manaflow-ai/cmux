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
    var dragID: UUID { registration.id }
    let registration: CloudTreeDragRegistration
    let machineOrdering: CloudMachineOrderingActions?
    private var sourceView: NSOutlineView?
    private var coordinator: CloudTreeOutlineView.Coordinator?

    init(
        registration: CloudTreeDragRegistration,
        sourceView: NSOutlineView,
        coordinator: CloudTreeOutlineView.Coordinator,
        provisionalToken: ProvisionalDragWriterOwnership.Token,
        nodeID: String? = nil,
        machineOrdering: CloudMachineOrderingActions? = nil
    ) {
        self.registration = registration
        self.machineOrdering = machineOrdering
        self.sourceView = sourceView
        self.coordinator = coordinator
        self.provisionalToken = provisionalToken
        super.init()
        // Organization-only sources must not expose a pane-opening capability.
        // They still use this writer so provisional/native ownership is shared.
        materializeRegistrationPayload()
        if let nodeID { setString(nodeID, forType: .cloudSidebarRow) }
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
        // materializeRegistrationPayload copies onto self with setString/setData.
        // Advertise this item's actual storage, including the sidebar-only case.
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard types.contains(type) else { return nil }
        if type == .cloudSidebarRow { return string(forType: type) }
        // `TabDragTransferRegistration` stores its capability as a raw string
        // and the surface record as raw JSON bytes. `propertyList(forType:)`
        // only reads values written with `setPropertyList`, so proxy each
        // representation through the matching accessor before falling back to
        // a true property-list value.
        return registration.pasteboardRegistration?.pasteboardItem.string(forType: type)
            ?? registration.pasteboardRegistration?.pasteboardItem.data(forType: type)
            ?? registration.pasteboardRegistration?.pasteboardItem.propertyList(forType: type)
    }

    /// Copies the registration into ``NSPasteboardItem`` storage before AppKit
    /// binds this item to a drag pasteboard. AppKit may use an item directly
    /// (without asking the ``NSPasteboardWriting`` accessors), so keeping the
    /// concrete item populated is required for both code paths.
    private func materializeRegistrationPayload() {
        guard let item = registration.pasteboardRegistration?.pasteboardItem else { return }
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
