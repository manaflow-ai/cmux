import Bonsplit
import Foundation

/// Process-local capability for the one sidebar workspace row being dragged:
/// pane drop targets resolve its opaque Bonsplit lease here and merge that
/// workspace's tabs (`AppDelegate.mergeWorkspace`). Same shape as
/// `SurfaceResourceDragRegistry`.
@MainActor
final class WorkspaceMergeDragRegistry {
    static let shared = WorkspaceMergeDragRegistry()

    private enum State {
        case idle
        case active(id: UUID, workspaceId: UUID)
    }

    private var state: State = .idle

    func register(workspaceId: UUID) -> UUID {
        let id = UUID()
        // AppKit runs one process-local drag at a time; a new registration
        // also invalidates an abandoned one's residual payload.
        state = .active(id: id, workspaceId: workspaceId)
        return id
    }

    func workspaceId(id: UUID) -> UUID? {
        guard case .active(let activeID, let workspaceId) = state, activeID == id else { return nil }
        return workspaceId
    }

    func discard(id: UUID) {
        guard workspaceId(id: id) != nil else { return }
        state = .idle
    }
}

/// Registers a sidebar workspace row as the live capability Bonsplit tab drags
/// use, so every pane drop target shows its zones and preview for it. The lease
/// never names a live pane; the sidebar still reads the row's reorder payload.
struct WorkspaceMergeDragPayload {
    let title: String
    let tabCount: Int
    let dragID: UUID

    /// The merge capability for a workspace row's drag, registered in the shared
    /// registry; nil when the app or the workspace is gone.
    @MainActor
    static func registering(_ workspaceId: UUID) -> (registry: TabDragTransferRegistry, payload: Self)? {
        guard let app = AppDelegate.shared,
              let workspace = app.tabManagerFor(tabId: workspaceId)?.tabs.first(where: { $0.id == workspaceId }) else {
            return nil
        }
        let dragID = WorkspaceMergeDragRegistry.shared.register(workspaceId: workspaceId)
        return (app.tabDragTransferRegistry, Self(title: workspace.title, tabCount: workspace.panels.count, dragID: dragID))
    }

    @MainActor
    func register(with registry: TabDragTransferRegistry) -> TabDragTransferRegistration? {
        registry.register(TabDragTransfer(
            tab: Bonsplit.Tab(id: TabID(uuid: dragID), title: title,
                              icon: tabCount > 1 ? "square.stack" : "terminal.fill", kind: "terminal"),
            sourcePaneId: PaneID(id: dragID)
        ))
    }
}
