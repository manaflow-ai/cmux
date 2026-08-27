import Bonsplit
import Foundation

/// Registers a Cloud tree row as the same live capability Bonsplit tab drags
/// use, so every existing pane drop target accepts it, and stamps the item with
/// the surface-resource type so the payload names catalog resources (terminals,
/// screens, browsers on this Mac or on a machine — one, or a whole workspace's
/// worth), never a pane.
struct SurfaceResourceDragPayload {
    static let pasteboardType = DragOverlayRoutingPolicy.surfaceResourceTransferType

    let group: SurfaceResourceGroup
    /// The kind of the first resource, which decides the Bonsplit tab icon/kind.
    let leadKind: SurfaceResourceKind
    let dragID: UUID

    @MainActor
    func register(with registry: TabDragTransferRegistry) -> TabDragTransferRegistration? {
        let kind: String
        let icon: String
        switch leadKind {
        case .terminal:
            kind = "terminal"
            icon = group.resources.count > 1 ? "square.stack" : "terminal.fill"
        case .screen:
            kind = "browser"
            icon = "display"
        case .browser:
            kind = "browser"
            icon = "globe"
        }
        guard let registration = registry.register(TabDragTransfer(
            tab: Bonsplit.Tab(id: TabID(uuid: dragID), title: group.title, icon: icon, kind: kind),
            // External source: this identity intentionally never names a live pane.
            sourcePaneId: PaneID(id: dragID)
        )) else {
            return nil
        }
        let record = SurfaceResourceDragPasteboardRecord(dragID: dragID, resources: group.resources.map(\.rawValue), title: group.title)
        if let data = try? JSONEncoder().encode(record) {
            registration.pasteboardItem.setData(data, forType: Self.pasteboardType)
        }
        return registration
    }
}

/// What the surface-resource pasteboard type carries; the drop side still
/// resolves the live group through `SurfaceResourceDragRegistry` by `dragID`.
/// A single-row drag is a one-element list.
struct SurfaceResourceDragPasteboardRecord: Codable, Equatable {
    let dragID: UUID
    /// `SurfaceResourceID.rawValue`s (`<machine>/<kind>/<key>`), in open order.
    let resources: [String]
    let title: String

    var resourceIDs: [SurfaceResourceID] { resources.compactMap(SurfaceResourceID.init(rawValue:)) }
}
