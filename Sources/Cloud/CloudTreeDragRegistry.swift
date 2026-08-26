import Foundation

/// Process-local capability registry for the one active Cloud-tree drag.
///
/// The pasteboard carries only an opaque UUID (Bonsplit tab-transfer lease);
/// pane drop targets resolve it here while the outline's drag session is alive.
/// Same shape as `SessionDragRegistry`; `shared` follows the app-target
/// precedent (`FilePreviewDragRegistry.shared`) because the drop resolver has no
/// injection seam for a fourth registry.
@MainActor
final class CloudTreeDragRegistry {
    static let shared = CloudTreeDragRegistry()

    private enum State {
        case idle
        case active(id: UUID, item: CloudTreeDragItem)
    }

    private var state: State = .idle

    func register(_ item: CloudTreeDragItem) -> UUID {
        let id = UUID()
        // AppKit permits only one process-local drag at a time; replacing an
        // abandoned registration also invalidates its residual payload.
        state = .active(id: id, item: item)
        return id
    }

    func item(id: UUID) -> CloudTreeDragItem? {
        guard case .active(let activeID, let item) = state, activeID == id else { return nil }
        return item
    }

    func discard(id: UUID) {
        guard item(id: id) != nil else { return }
        state = .idle
    }
}
