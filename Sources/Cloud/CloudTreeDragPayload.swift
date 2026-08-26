import Bonsplit
import Foundation

/// Registers a Cloud tree row as the same live capability Bonsplit tab drags
/// use, so every existing pane drop target accepts it, and stamps the item with
/// the cloud-surface type so the payload names a daemon-side resource (a
/// machine's terminal, desktop, or port) rather than a local pane.
struct CloudTreeDragPayload {
    static let pasteboardType = DragOverlayRoutingPolicy.cloudSurfaceTransferType

    let item: CloudTreeDragItem
    let dragID: UUID
    let title: String

    @MainActor
    func register(with registry: TabDragTransferRegistry) -> TabDragTransferRegistration? {
        let kind: String
        let icon: String
        switch item {
        case .terminal:
            kind = "terminal"
            icon = "terminal.fill"
        case .desktop:
            kind = "browser"
            icon = "display"
        case .port:
            kind = "browser"
            icon = "globe"
        }
        guard let registration = registry.register(TabDragTransfer(
            tab: Bonsplit.Tab(id: TabID(uuid: dragID), title: title, icon: icon, kind: kind),
            // External source: this identity intentionally never names a live pane.
            sourcePaneId: PaneID(id: dragID)
        )) else {
            return nil
        }
        if let data = try? JSONEncoder().encode(CloudTreeDragPasteboardRecord(dragID: dragID, item: item)) {
            registration.pasteboardItem.setData(data, forType: Self.pasteboardType)
        }
        return registration
    }
}

/// What the cloud-surface pasteboard type carries; the drop side still resolves
/// the live item through `CloudTreeDragRegistry` by `dragID`.
struct CloudTreeDragPasteboardRecord: Codable, Equatable {
    let dragID: UUID
    let item: CloudTreeDragItem
}
