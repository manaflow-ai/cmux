public import Foundation

/// The workspace-side seam ``SurfaceTeardownCoordinator`` drives the live
/// workspace state through while tearing down every panel in the workspace
/// before `TabManager` removes it.
///
/// **Why a synchronous read/write protocol and not value snapshots.**
/// ``SurfaceTeardownCoordinator/teardownAllPanels()`` runs as one `@MainActor`
/// turn that disables portal rendering, cancels the pending layout follow-up,
/// hides the terminal and browser portal views, discards each panel's close
/// lifecycle state (closing the bonsplit tab and publishing the surface-closed
/// event so child processes receive SIGHUP even if ARC deallocation is delayed),
/// prunes the per-surface metadata, re-syncs the remote port scan, recomputes
/// the listening ports, clears the remote configuration if the workspace became
/// local, and drops the per-panel scrollback / pending-input-observer /
/// terminal-config-inheritance bookkeeping, exactly as the legacy
/// `Workspace.teardownAllPanels` body did. Every one of those reads and side
/// effects is owned by the app-target `Workspace` (the portal views, the
/// `any Panel` registry, the 10-argument app close-lifecycle helper, the
/// remote/port accounting, and the inheritance dictionaries all live there and
/// touch app-only types), so none of it can move into the package. The
/// coordinator reaches all of it through this seam so it never holds the
/// app-target `Workspace`, while every value it sees and every side effect it
/// triggers stay on the live state.
///
/// The witnesses mirror the legacy inline statements one-for-one, in the order
/// the coordinator invokes them, reproducing the exact teardown sequence. The
/// per-panel discard loop is a single witness because it iterates the
/// `any Panel` registry and calls `discardClosedPanelLifecycleState`, both
/// app-only; keeping the loop host-side preserves the legacy
/// `for (panelId, panel) in Array(panels)` ordering and argument set verbatim.
@MainActor
public protocol SurfaceTeardownHosting: AnyObject {
    /// The owning workspace's identity, kept for parity with the sibling
    /// hosting seams (legacy `Workspace.id`).
    var workspaceId: UUID { get }

    /// Disables portal rendering for the workspace (legacy
    /// `Workspace.portalRenderingEnabled = false`).
    func disablePortalRendering()

    /// Cancels any pending layout follow-up work (legacy
    /// `Workspace.clearLayoutFollowUp()`; the workspace forwards from a
    /// distinctly named witness because the legacy body is `private`).
    func surfaceTeardownClearLayoutFollowUp()

    /// Hides every terminal portal view in the workspace (legacy
    /// `Workspace.hideAllTerminalPortalViews()`).
    func hideAllTerminalPortalViews()

    /// Hides every browser portal view in the workspace (legacy
    /// `Workspace.hideAllBrowserPortalViews()`).
    func hideAllBrowserPortalViews()

    /// Discards the close lifecycle state for every panel currently in the
    /// workspace, in registry-iteration order, closing each bonsplit tab and
    /// publishing its surface-closed event so child processes receive SIGHUP
    /// (legacy `for (panelId, panel) in Array(panels) {
    /// discardClosedPanelLifecycleState(...) }` with `origin: "workspace_teardown"`
    /// and every flag set, the `any Panel` loop kept host-side).
    func discardAllPanelsForTeardown()

    /// Prunes the per-surface metadata down to no valid surfaces (legacy
    /// `Workspace.pruneSurfaceMetadata(validSurfaceIds: [])`).
    func pruneAllSurfaceMetadata()

    /// Re-syncs the remote port scan TTYs after the surfaces are gone (legacy
    /// `Workspace.syncRemotePortScanTTYs()`).
    func syncRemotePortScanTTYs()

    /// Recomputes the workspace's listening ports (legacy
    /// `Workspace.recomputeListeningPorts()`).
    func recomputeListeningPorts()

    /// Clears the remote configuration if removing the last surface made the
    /// workspace local (legacy
    /// `Workspace.clearRemoteConfigurationIfWorkspaceBecameLocal()`; the
    /// workspace forwards from a distinctly named witness because the legacy body
    /// is `private`).
    func surfaceTeardownClearRemoteConfigurationIfWorkspaceBecameLocal()

    /// Drops the per-panel teardown bookkeeping that has no app-coupled effect:
    /// the restored-scrollback cache, the DEBUG session-snapshot scrollback
    /// fallback/synthetic dictionaries, the pending-terminal-input observers, and
    /// the terminal-config inheritance state (legacy tail of
    /// `Workspace.teardownAllPanels`: the `restoredTerminalScrollbackByPanelId` /
    /// `#if DEBUG` scrollback / `pendingTerminalInputObserversByPanelId` /
    /// `terminalInheritanceFontPointsByPanelId` / `lastTerminalConfigInheritance*`
    /// resets). The DEBUG-only resets are no-ops in release builds, matching the
    /// legacy `#if DEBUG` guard.
    func clearPerPanelTeardownBookkeeping()
}
