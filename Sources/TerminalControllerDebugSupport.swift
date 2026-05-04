#if DEBUG
import Foundation

extension TerminalController {
    func v2DebugTerminalFirstResponderFocus(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let resolvedWorkspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let owner = AppDelegate.shared?.locateSurface(surfaceId: surfaceId)
            let workspace = owner.flatMap { located in
                located.tabManager.tabs.first { $0.id == located.workspaceId }
            } ?? resolvedWorkspace
            guard let panel = workspace.panels[surfaceId] else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let accepted = AppDelegate.shared?.requestTerminalFirstResponderFocus(workspaceId: workspace.id, panel: panel) ?? false
            cmuxDebugLog(
                "debug.terminal.firstResponderFocus " +
                    "requestedWorkspace=\(resolvedWorkspace.id.uuidString.prefix(5)) " +
                    "ownerWorkspace=\(workspace.id.uuidString.prefix(5)) " +
                    "surface=\(surfaceId.uuidString.prefix(5)) accepted=\(accepted ? 1 : 0) " +
                    "ownerFound=\((owner != nil) ? 1 : 0)"
            )
            result = .ok([
                "accepted": accepted,
                "requested_workspace_id": resolvedWorkspace.id.uuidString,
                "requested_workspace_ref": v2Ref(kind: .workspace, uuid: resolvedWorkspace.id),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "current_surface_id": v2OrNull(workspace.focusedPanelId?.uuidString),
                "current_surface_ref": v2Ref(kind: .surface, uuid: workspace.focusedPanelId)
            ])
        }
        return result
    }

    func v2DebugPortalStats() -> V2CallResult {
        let payload: [String: Any] = v2MainSync {
            TerminalWindowPortalRegistry.debugPortalStats()
        }
        return .ok(payload)
    }
}
#endif
