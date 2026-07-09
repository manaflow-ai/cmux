import Foundation

/// Drives a workspace's whole-workspace teardown against the live state: freeing
/// every panel's Ghostty surface before `TabManager` removes the workspace, so
/// child processes receive SIGHUP even if ARC deallocation is delayed.
///
/// This command is lifted one-for-one from the legacy `Workspace.teardownAllPanels`
/// body. The teardown touches only app-target state (the portal views, the
/// `any Panel` registry and its 10-argument close-lifecycle helper, the
/// remote/port accounting, and the per-panel inheritance dictionaries), so every
/// step is reached through ``SurfaceTeardownHosting`` and this type never holds
/// the app-target `Workspace`, while the state it mutates and the surface-closed
/// events it triggers are always the live ones. The coordinator owns only the
/// fixed teardown ordering; it holds no state of its own.
///
/// `@MainActor` because the teardown runs as one main-actor turn driven by
/// `TabManager` removing a workspace, and the host lives there — co-locating
/// removes any bridging, the same isolation ruling as the sibling
/// ``SplitCloseCoordinator`` / ``SplitDetachCoordinator`` seams.
@MainActor
public final class SurfaceTeardownCoordinator {
    private weak var host: (any SurfaceTeardownHosting)?

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    public init() {}

    /// Attaches the workspace-side host the teardown drives through.
    public func attach(host: any SurfaceTeardownHosting) {
        self.host = host
    }

    /// Tears down every panel in the workspace, freeing their Ghostty surfaces,
    /// in the exact order the legacy `Workspace.teardownAllPanels` body ran:
    /// disable portal rendering, clear the layout follow-up, hide the terminal
    /// and browser portals, discard each panel's close lifecycle state, prune the
    /// surface metadata, re-sync the remote port scan, recompute the listening
    /// ports, clear the remote configuration if the workspace became local, and
    /// drop the per-panel teardown bookkeeping. Lifted one-for-one from
    /// `Workspace.teardownAllPanels`.
    public func teardownAllPanels() {
        guard let host else { return }
        host.disablePortalRendering()
        host.surfaceTeardownClearLayoutFollowUp()
        host.hideAllTerminalPortalViews()
        host.hideAllBrowserPortalViews()
        host.discardAllPanelsForTeardown()
        host.pruneAllSurfaceMetadata()
        host.syncRemotePortScanTTYs()
        host.recomputeListeningPorts()
        host.surfaceTeardownClearRemoteConfigurationIfWorkspaceBecameLocal()
        host.clearPerPanelTeardownBookkeeping()
    }
}
