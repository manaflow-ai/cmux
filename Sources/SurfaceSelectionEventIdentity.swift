import Foundation
import CmuxControlSocket

/// IDs and stable v2 refs attached to a selection event.
nonisolated struct SurfaceSelectionEventIdentity: Equatable, Sendable {
    let workspaceId: UUID
    let workspaceRef: String
    let surfaceId: UUID
    let surfaceRef: String
    let paneId: UUID?
    let paneRef: String?
    let windowId: UUID?
    let windowRef: String?

    init(
        workspaceId: UUID,
        workspaceRef: String,
        surfaceId: UUID,
        surfaceRef: String,
        paneId: UUID? = nil,
        paneRef: String? = nil,
        windowId: UUID? = nil,
        windowRef: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.workspaceRef = workspaceRef
        self.surfaceId = surfaceId
        self.surfaceRef = surfaceRef
        self.paneId = paneId
        self.paneRef = paneRef
        self.windowId = windowId
        self.windowRef = windowRef
    }

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
