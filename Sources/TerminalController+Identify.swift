import CmuxControlSocket
import Foundation

extension TerminalController {
    func v2IdentifyCallerPayload(
        callerObj: [String: Any],
        fallbackTabManager tabManager: TabManager
    ) -> [String: Any]? {
        let requestedWorkspaceId = v2UUIDAny(callerObj["workspace_id"])
        let surfaceId = v2UUIDAny(callerObj["surface_id"]) ?? v2UUIDAny(callerObj["tab_id"])
        var location: (tabManager: TabManager, workspace: Workspace)?

        if let surfaceId {
            if let located = AppDelegate.shared?.workspaceContainingPanel(
                panelId: surfaceId,
                preferredWorkspaceId: requestedWorkspaceId
            ) {
                location = (located.tabManager, located.workspace)
            } else if let workspace = tabManager.tabs.first(where: {
                $0.panels[surfaceId] != nil && $0.surfaceIdFromPanelId(surfaceId) != nil
            }) {
                location = (tabManager, workspace)
            }
        }

        if location == nil,
           let requestedWorkspaceId {
            let workspaceManager = AppDelegate.shared?.tabManagerFor(tabId: requestedWorkspaceId) ?? tabManager
            if let workspace = workspaceManager.tabs.first(where: { $0.id == requestedWorkspaceId }) {
                location = (workspaceManager, workspace)
            }
        }

        guard let location else { return nil }
        return v2IdentifyCallerPayload(
            tabManager: location.tabManager,
            workspace: location.workspace,
            surfaceId: surfaceId
        )
    }

    private func v2IdentifyCallerPayload(
        tabManager callerTabManager: TabManager,
        workspace ws: Workspace,
        surfaceId: UUID?
    ) -> [String: Any] {
        let wsId = ws.id
        let callerWindowId = v2ResolveWindowId(tabManager: callerTabManager)
        var payload: [String: Any] = [
            "window_id": v2OrNull(callerWindowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: callerWindowId),
            "workspace_id": wsId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
        ]

        guard let surfaceId, ws.panels[surfaceId] != nil else {
            payload["surface_id"] = NSNull()
            payload["surface_ref"] = NSNull()
            payload["tab_id"] = NSNull()
            payload["tab_ref"] = NSNull()
            payload["surface_type"] = NSNull()
            payload["is_browser_surface"] = NSNull()
            payload["pane_id"] = NSNull()
            payload["pane_ref"] = NSNull()
            return payload
        }

        let paneUUID = ws.paneId(forPanelId: surfaceId)?.id
        payload["surface_id"] = surfaceId.uuidString
        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
        payload["tab_id"] = surfaceId.uuidString
        payload["tab_ref"] = v2TabRef(uuid: surfaceId)
        payload["surface_type"] = v2OrNull(ws.panels[surfaceId]?.panelType.rawValue)
        payload["is_browser_surface"] = v2OrNull(ws.panels[surfaceId]?.panelType == .browser)
        payload["pane_id"] = v2OrNull(paneUUID?.uuidString)
        payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneUUID)
        return payload
    }
}
