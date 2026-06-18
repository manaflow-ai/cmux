public import Foundation

/// Sidebar git metadata probing for workspace panels: local branch/dirty
/// probes with retry, filesystem watchers on git paths, and the slow
/// fallback re-poll.
///
/// Implemented by ``SidebarGitMetadataService``; the host (per-window
/// `TabManager`) stores this seam, never the concrete type, and forwards its
/// legacy entry points here. Method names match the legacy `TabManager`
/// methods one-for-one so the lift stays reviewable against the original.
@MainActor
public protocol SidebarGitMetadataServing: AnyObject {
    /// Wires the host seam and captures the initial watch-setting value.
    /// Must be called once, before any scheduling entry point.
    func attach(host: any SidebarGitHosting)
    /// Schedules the multi-attempt initial probe for a panel (retry offsets
    /// 0, 0.5, 1.5, 3, 6, 10 seconds), unless the workspace is remote.
    func scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String
    )
    /// Records a panel's directory change and reschedules probes when the
    /// effective probe directory changed.
    func updateSurfaceDirectory(workspaceId: UUID, panelId: UUID, directory: String)
    /// Applies an externally reported branch (e.g. OSC sequence) and
    /// reschedules probes and PR refresh.
    func updateSurfaceGitBranch(workspaceId: UUID, panelId: UUID, branch: String, isDirty: Bool?)
    /// Clears a panel's branch/badge state and re-probes the directory.
    func clearSurfaceGitBranch(workspaceId: UUID, panelId: UUID)
    /// Re-probes every tracked poll candidate panel (fallback timer body).
    func refreshTrackedWorkspaceGitMetadata(reason: String)
    /// Reacts to the sidebar git watch setting toggling (tear down or
    /// restart watching).
    func sidebarGitMetadataWatchSettingsDidChange()
    /// Clears all probe state for a closing/detaching workspace.
    func clearWorkspaceGitProbes(workspaceId: UUID)
    /// Clears every probe and tracked directory (session restore swap).
    func resetAllWorkspaceGitProbeTracking()
    /// Panel ids the fallback poll would currently re-probe (test seam).
    func trackedWorkspaceGitMetadataPollCandidatePanelIds(workspaceId: UUID) -> Set<UUID>
    /// Panel ids with live probe state or probe tasks (test seam).
    func activeWorkspaceGitProbePanelIds(workspaceId: UUID) -> Set<UUID>
}
