import os

/// Correlates the local pane, remote terminal and remote view at ownership fences.
struct CloudTerminalLifecycleLog {
    func rejected(_ projection: SurfaceProjection, stage: String) {
        Logger(subsystem: "com.cmuxterm.app", category: "CloudTerminalLifecycle").notice(
            "view.rejected stage=\(stage, privacy: .public) machine=\(projection.resource.machine.rawValue, privacy: .private(mask: .hash)) workspace=\(projection.workspaceID.uuidString, privacy: .private(mask: .hash)) panel=\(projection.panelID.uuidString, privacy: .private(mask: .hash)) terminal=\(projection.resource.key, privacy: .private(mask: .hash)) remoteWorkspace=\(projection.remoteWorkspaceID ?? "", privacy: .private(mask: .hash)) tab=\(projection.remoteTabID ?? "", privacy: .private(mask: .hash))"
        )
    }
}
