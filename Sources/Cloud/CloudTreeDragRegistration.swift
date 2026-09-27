import Bonsplit
import Foundation

/// One lifetime for native row drags, with projection capability only for
/// terminal/display sources. Folder organization works even with no resources.
@MainActor
enum CloudTreeDragRegistration {
    case organization(UUID)
    case projection(UUID, TabDragTransferRegistration, TabDragTransferRegistry)

    init?(node: CloudTreeNode, registry: TabDragTransferRegistry?) {
        if (node.canOrganize || node.canReorderMachine) && !node.isDragSource {
            self = .organization(UUID())
            return
        }
        guard node.isDragSource, let group = node.dragGroup,
              let lead = group.resources.first, let registry else { return nil }
        let id = SurfaceResourceDragRegistry.shared.register(group)
        guard let registration = SurfaceResourceDragPayload(group: group, leadKind: lead.kind, dragID: id).register(with: registry) else {
            SurfaceResourceDragRegistry.shared.discard(id: id)
            return nil
        }
        self = .projection(id, registration, registry)
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
