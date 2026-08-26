import Bonsplit
import Foundation

/// Registers a Cloud tree row as the same live capability Bonsplit tab drags
/// use, so every existing pane drop target accepts it, and stamps the item with
/// the surface-resource type so the payload names a catalog resource (a
/// terminal, screen, or browser on this Mac or on a machine), never a pane.
struct SurfaceResourceDragPayload {
    static let pasteboardType = DragOverlayRoutingPolicy.surfaceResourceTransferType

    let resource: SurfaceResource
    let dragID: UUID

    @MainActor
    func register(with registry: TabDragTransferRegistry) -> TabDragTransferRegistration? {
        let kind: String
        let icon: String
        switch resource.kind {
        case .terminal:
            kind = "terminal"
            icon = "terminal.fill"
        case .screen:
            kind = "browser"
            icon = "display"
        case .browser:
            kind = "browser"
            icon = "globe"
        }
        guard let registration = registry.register(TabDragTransfer(
            tab: Bonsplit.Tab(id: TabID(uuid: dragID), title: resource.title, icon: icon, kind: kind),
            // External source: this identity intentionally never names a live pane.
            sourcePaneId: PaneID(id: dragID)
        )) else {
            return nil
        }
        if let data = try? JSONEncoder().encode(SurfaceResourceDragPasteboardRecord(dragID: dragID, resource: resource.id.rawValue)) {
            registration.pasteboardItem.setData(data, forType: Self.pasteboardType)
        }
        return registration
    }
}

/// What the surface-resource pasteboard type carries; the drop side still
/// resolves the live resource through `SurfaceResourceDragRegistry` by `dragID`.
struct SurfaceResourceDragPasteboardRecord: Codable, Equatable {
    let dragID: UUID
    /// `SurfaceResourceID.rawValue` (`<machine>/<kind>/<key>`).
    let resource: String
}
