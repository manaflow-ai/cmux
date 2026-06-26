import CmuxPanes
import Foundation

/// `Workspace` is the live host for its ``SurfaceTeardownCoordinator``. Every
/// member either passes through to an existing `Workspace` teardown helper or
/// reads/writes the workspace's own per-panel bookkeeping, reproducing the
/// statements the legacy `teardownAllPanels` body ran inline and in the same
/// order. The coordinator is held by `Workspace` and references this host
/// weakly, so there is no retain cycle.
///
/// The witnesses that touch `private` `Workspace` state
/// (`disablePortalRendering`, `clearLayoutFollowUp`,
/// `discardAllPanelsForTeardown`, `clearRemoteConfigurationIfWorkspaceBecameLocal`,
/// `clearPerPanelTeardownBookkeeping`) are co-located with that private state in
/// `Workspace.swift` rather than widening those members to `internal` for this
/// cross-file conformance, matching the ``SplitDetachHosting`` precedent. The
/// remaining witnesses below forward to already-`internal` `Workspace` helpers
/// (`hideAllTerminalPortalViews`, `hideAllBrowserPortalViews`,
/// `pruneSurfaceMetadata`, `syncRemotePortScanTTYs`, `recomputeListeningPorts`)
/// and `workspaceId` is declared in the ``SplitMoveReorderHosting`` conformance,
/// so this file only declares the conformance and the internal-reachable
/// witnesses.
extension Workspace: SurfaceTeardownHosting {
    func pruneAllSurfaceMetadata() {
        pruneSurfaceMetadata(validSurfaceIds: [])
    }
}
