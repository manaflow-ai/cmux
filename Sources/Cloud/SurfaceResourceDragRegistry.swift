import Foundation

/// Process-local capability registry for the one active surface drag from the
/// Cloud tree: a group of resources (a single row is a one-element group; a
/// workspace row is its terminals and browsers).
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
        case active(id: UUID, group: SurfaceResourceGroup)
    }

    private var state: State = .idle

    func register(_ group: SurfaceResourceGroup) -> UUID {
        let id = UUID()
        // AppKit permits only one process-local drag at a time; replacing an
        // abandoned registration also invalidates its residual payload.
        state = .active(id: id, group: group)
        return id
    }

    func group(id: UUID) -> SurfaceResourceGroup? {
        guard case .active(let activeID, let group) = state, activeID == id else { return nil }
        return group
    }

    func discard(id: UUID) {
        guard group(id: id) != nil else { return }
        state = .idle
    }
}
