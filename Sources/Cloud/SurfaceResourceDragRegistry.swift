import Foundation

/// Process-local capability registry for the one active surface drag from the
/// Cloud tree.
///
/// The pasteboard carries only an opaque UUID (Bonsplit tab-transfer lease);
/// pane drop targets resolve it here while the outline's drag session is alive.
/// Same shape as `SessionDragRegistry`; `shared` follows the app-target
/// precedent (`FilePreviewDragRegistry.shared`) because the drop resolver has no
/// injection seam for a fourth registry.
@MainActor
final class SurfaceResourceDragRegistry {
    static let shared = SurfaceResourceDragRegistry()

    private enum State {
        case idle
        case active(id: UUID, resource: SurfaceResourceID)
    }

    private var state: State = .idle

    func register(_ resource: SurfaceResourceID) -> UUID {
        let id = UUID()
        // AppKit permits only one process-local drag at a time; replacing an
        // abandoned registration also invalidates its residual payload.
        state = .active(id: id, resource: resource)
        return id
    }

    func resource(id: UUID) -> SurfaceResourceID? {
        guard case .active(let activeID, let resource) = state, activeID == id else { return nil }
        return resource
    }

    func discard(id: UUID) {
        guard resource(id: id) != nil else { return }
        state = .idle
    }
}
