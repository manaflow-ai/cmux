import Foundation
import CmuxControlSocket
import CmuxSurfaceSelection

typealias SurfaceSelectionEventIdentity = CmuxSurfaceSelection.SurfaceSelectionEventIdentity

extension CmuxSurfaceSelection.SurfaceSelectionEventIdentity {
    /// Resolves current app-owned refs without making the reusable value type
    /// depend on app or workspace objects.
    @MainActor
    static func live(workspaceId: UUID, surfaceId: UUID) -> Self {
        let workspace = AppDelegate.shared?
            .tabManagerFor(tabId: workspaceId)?
            .workspacesById[workspaceId]
        let paneId = workspace?.paneId(forPanelId: surfaceId)?.id
        let tabManager = workspace?.owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
        let windowId = tabManager.flatMap { AppDelegate.shared?.windowId(for: $0) }
        let controller = TerminalController.shared
        return Self(
            workspaceId: workspaceId,
            workspaceRef: (controller.v2Ref(kind: .workspace, uuid: workspaceId) as? String)
                ?? "workspace:\(workspaceId.uuidString)",
            surfaceId: surfaceId,
            surfaceRef: (controller.v2Ref(kind: .surface, uuid: surfaceId) as? String)
                ?? "surface:\(surfaceId.uuidString)",
            paneId: paneId,
            paneRef: paneId.map {
                (controller.v2Ref(kind: .pane, uuid: $0) as? String)
                    ?? "pane:\($0.uuidString)"
            },
            windowId: windowId,
            windowRef: windowId.map {
                (controller.v2Ref(kind: .window, uuid: $0) as? String)
                    ?? "window:\($0.uuidString)"
            }
        )
    }
}
