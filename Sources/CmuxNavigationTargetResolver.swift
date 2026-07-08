import CmuxRemoteWorkspace
import Foundation

/// Pure resolution logic for `cmux://workspace/...` navigation deep links.
///
/// Links can carry either a session-scoped runtime identifier (the workspace or
/// panel `id`, re-minted every launch) or a restart-stable identifier
/// (``Workspace/stableId`` / ``Panel/stableSurfaceId``, persisted in the session
/// snapshot and re-adopted on restore). The resolver tries the runtime
/// identifier first — it is authoritative for anything minted this session —
/// and falls back to the stable identifier so links keep working after an app
/// restart. Surface routes additionally fall back to a cross-workspace search
/// so a link survives its tab being dragged to another workspace.
///
/// The type is a plain value over snapshot descriptors so the resolution rules
/// are unit-testable without launching the app.
struct CmuxNavigationTargetResolver {
    typealias SurfaceDescriptor = CmuxNavigationSurfaceDescriptor
    typealias WorkspaceDescriptor = CmuxNavigationWorkspaceDescriptor
    typealias Resolution = CmuxNavigationResolution

    let workspaces: [WorkspaceDescriptor]
    private let workspaceByRuntimeId: [UUID: WorkspaceDescriptor]
    private let workspaceByStableId: [UUID: WorkspaceDescriptor]
    private let surfaceByRuntimeId: [UUID: (workspaceId: UUID, panelId: UUID)]
    private let surfaceByStableId: [UUID: (workspaceId: UUID, panelId: UUID)]

    init(workspaces: [WorkspaceDescriptor]) {
        self.workspaces = workspaces
        var workspaceByRuntimeId: [UUID: WorkspaceDescriptor] = [:]
        var workspaceByStableId: [UUID: WorkspaceDescriptor] = [:]
        var surfaceByRuntimeId: [UUID: (workspaceId: UUID, panelId: UUID)] = [:]
        var surfaceByStableId: [UUID: (workspaceId: UUID, panelId: UUID)] = [:]
        workspaceByRuntimeId.reserveCapacity(workspaces.count)
        workspaceByStableId.reserveCapacity(workspaces.count)
        for workspace in workspaces {
            if workspaceByRuntimeId[workspace.workspaceId] == nil {
                workspaceByRuntimeId[workspace.workspaceId] = workspace
            }
            if workspaceByStableId[workspace.stableId] == nil {
                workspaceByStableId[workspace.stableId] = workspace
            }
            for surface in workspace.surfaces {
                if surfaceByRuntimeId[surface.panelId] == nil {
                    surfaceByRuntimeId[surface.panelId] = (workspace.workspaceId, surface.panelId)
                }
                if surfaceByStableId[surface.stableSurfaceId] == nil {
                    surfaceByStableId[surface.stableSurfaceId] = (workspace.workspaceId, surface.panelId)
                }
            }
        }
        self.workspaceByRuntimeId = workspaceByRuntimeId
        self.workspaceByStableId = workspaceByStableId
        self.surfaceByRuntimeId = surfaceByRuntimeId
        self.surfaceByStableId = surfaceByStableId
    }

    /// Resolves a parsed navigation target to current-session identifiers, or
    /// nil when no open workspace/pane/surface matches either identity.
    func resolve(_ target: CmuxNavigationURLRequest.Target) -> Resolution? {
        switch target {
        case .workspace(let workspaceId):
            return resolveWorkspace(workspaceId).map { .workspace(workspaceId: $0.workspaceId) }
        case .pane(let workspaceId, let paneId):
            guard let workspace = resolveWorkspace(workspaceId),
                  workspace.paneIds.contains(paneId) else {
                return nil
            }
            return .pane(workspaceId: workspace.workspaceId, paneId: paneId)
        case .surface(let workspaceId, let surfaceId):
            let linkedWorkspace = resolveWorkspace(workspaceId)
            if let linkedWorkspace,
               let panelId = resolveSurface(surfaceId, in: linkedWorkspace) {
                return .surface(workspaceId: linkedWorkspace.workspaceId, panelId: panelId)
            }
            // The tab may have moved to another workspace since the link was
            // copied (or its workspace was closed); surface identity wins over
            // the stale workspace route. Exact runtime ids beat stable ids.
            let excludedWorkspaceId = linkedWorkspace?.workspaceId
            if let target = surfaceByRuntimeId[surfaceId],
               target.workspaceId != excludedWorkspaceId {
                return .surface(workspaceId: target.workspaceId, panelId: target.panelId)
            }
            if let target = surfaceByStableId[surfaceId],
               target.workspaceId != excludedWorkspaceId {
                return .surface(workspaceId: target.workspaceId, panelId: target.panelId)
            }
            return nil
        }
    }

    private func resolveWorkspace(_ id: UUID) -> WorkspaceDescriptor? {
        workspaceByRuntimeId[id] ?? workspaceByStableId[id]
    }

    private func resolveSurface(_ id: UUID, in workspace: WorkspaceDescriptor) -> UUID? {
        if workspace.surfaces.contains(where: { $0.panelId == id }) {
            return id
        }
        return workspace.surfaces.first(where: { $0.stableSurfaceId == id })?.panelId
    }
}
