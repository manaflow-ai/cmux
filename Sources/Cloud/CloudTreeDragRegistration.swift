import Bonsplit
import Foundation

/// One lifetime for native row drags, with projection capability for eligible
/// leaves and remote workspace groups. Folder organization works even with no
/// resources, and local workspace groups stay reorder-only.
@MainActor
enum CloudTreeDragRegistration {
    case organization(UUID)
    case projection(UUID, TabDragTransferRegistration, TabDragTransferRegistry)

    init?(node: CloudTreeNode, registry: TabDragTransferRegistry?) {
        if node.isDragSource, let group = node.dragGroup,
           let lead = group.resources.first, let registry {
            let id = SurfaceResourceDragRegistry.shared.register(group)
            if let registration = SurfaceResourceDragPayload(group: group, leadKind: lead.kind, dragID: id).register(with: registry) {
                self = .projection(id, registration, registry)
                return
            }
            SurfaceResourceDragRegistry.shared.discard(id: id)
        }
        // Sidebar organization remains available even when the pane projection
        // registry is unavailable or rejects a remote workspace's registration.
        guard node.canOrganize || node.canReorderMachine else { return nil }
        self = .organization(UUID())
    }

    var id: UUID {
        switch self {
        case .organization(let id), .projection(let id, _, _): return id
        }
    }

    var pasteboardRegistration: TabDragTransferRegistration? {
        guard case .projection(_, let registration, _) = self else { return nil }
        return registration
    }

    func end() {
        guard case .projection(let id, let registration, let registry) = self else { return }
        registry.end(registration)
        SurfaceResourceDragRegistry.shared.discard(id: id)
    }
}
