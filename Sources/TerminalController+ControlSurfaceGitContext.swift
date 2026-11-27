import CmuxControlSocket
import Foundation

extension TerminalController {
    func controlSurfaceReportGitBranch(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        branch: String,
        isDirty: Bool?
    ) -> ControlSurfaceReportGitBranchResolution {
        guard let workspace = controlTabForSidebarMutation(id: workspaceID) else {
            return .workspaceNotFound
        }
        let validSurfaceIDs = Set(workspace.panels.keys)
        workspace.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIDs)
        guard let surfaceID = controlResolveReportedSurfaceId(
            in: workspace,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIDs
        ), validSurfaceIDs.contains(surfaceID) else {
            return workspace.isRemoteWorkspace && validSurfaceIDs.isEmpty ? .pending : .surfaceNotFound
        }

        let existing = workspace.reportedPanelGitBranch(panelId: surfaceID)
        let resolvedIsDirty = isDirty ?? (existing?.branch == branch ? existing?.isDirty ?? false : false)
        if let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) ?? tabManager {
            manager.updateSurfaceGitBranch(
                tabId: workspaceID,
                surfaceId: surfaceID,
                branch: branch,
                isDirty: resolvedIsDirty
            )
        } else {
            workspace.updatePanelGitBranch(panelId: surfaceID, branch: branch, isDirty: resolvedIsDirty)
        }
        return .recorded(surfaceID: surfaceID)
    }

    func controlSurfaceClearGitBranch(
        workspaceID: UUID,
        requestedSurfaceID: UUID?
    ) -> ControlSurfaceReportGitBranchResolution {
        guard let workspace = controlTabForSidebarMutation(id: workspaceID) else {
            return .workspaceNotFound
        }
        let validSurfaceIDs = Set(workspace.panels.keys)
        workspace.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIDs)
        guard let surfaceID = controlResolveReportedSurfaceId(
            in: workspace,
            requestedSurfaceId: requestedSurfaceID,
            validSurfaceIds: validSurfaceIDs
        ), validSurfaceIDs.contains(surfaceID) else {
            return workspace.isRemoteWorkspace && validSurfaceIDs.isEmpty ? .pending : .surfaceNotFound
        }

        if let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID) ?? tabManager {
            manager.clearSurfaceGitBranch(tabId: workspaceID, surfaceId: surfaceID)
        } else {
            workspace.clearPanelGitBranch(panelId: surfaceID)
        }
        return .recorded(surfaceID: surfaceID)
    }
}
