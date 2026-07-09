import CmuxRemoteSession
import CmuxRemoteWorkspace
import Foundation

/// `Workspace` is the live host for its `RemoteSurfaceTTYCoordinator`. The
/// coordinator (in `CmuxRemoteWorkspace`) owns the pending remote-surface TTY /
/// port-kick bookkeeping bodies; this witness reproduces the slice of live
/// workspace state those bodies read or mutate: the four pending stored fields
/// (each get/set so they stay app-side, where connect/disconnect also resets
/// them), the per-surface TTY-name map (read and written per key), the active
/// remote-terminal surface id set and focused panel id (read to pick the
/// bootstrap candidate), the default `.command` port-kick reason, and the
/// port-scan TTY sync / per-panel port-scan kick (forwarded app-side to the
/// sibling `RemoteSurfaceCoordinator`).
///
/// `PortScanKickReason` lives in `CmuxRemoteSession`, a package above
/// `CmuxRemoteWorkspace` in the graph, so the coordinator carries the reason as
/// `RemoteSurfaceTTYHosting.PortKickReason` and this conformance pins it back to
/// the concrete type.
///
/// This mirrors the sibling `Workspace+RemoteSurfaceHosting` and
/// `Workspace+RemoteStatusHosting`: the lifted coordinator's live seam
/// conformance lives in its own app-target file so `Workspace.swift` drains the
/// bodies instead of trading them for inline seam glue. The coordinator is held
/// by `Workspace` and references this host weakly, so there is no retain cycle.
extension Workspace: RemoteSurfaceTTYHosting {
    typealias PortKickReason = PortScanKickReason

    var hostPendingRemoteSurfaceTTYName: String? {
        get { pendingRemoteSurfaceTTYName }
        set { pendingRemoteSurfaceTTYName = newValue }
    }

    var hostPendingRemoteSurfaceTTYSurfaceId: UUID? {
        get { pendingRemoteSurfaceTTYSurfaceId }
        set { pendingRemoteSurfaceTTYSurfaceId = newValue }
    }

    var hostPendingRemoteSurfacePortKickReason: PortScanKickReason? {
        get { pendingRemoteSurfacePortKickReason }
        set { pendingRemoteSurfacePortKickReason = newValue }
    }

    var hostPendingRemoteSurfacePortKickSurfaceId: UUID? {
        get { pendingRemoteSurfacePortKickSurfaceId }
        set { pendingRemoteSurfacePortKickSurfaceId = newValue }
    }

    func hostSurfaceTTYName(forPanel panelId: UUID) -> String? {
        surfaceTTYNames[panelId]
    }

    func hostSetSurfaceTTYName(_ name: String, forPanel panelId: UUID) {
        surfaceTTYNames[panelId] = name
    }

    var hostFocusedPanelId: UUID? {
        focusedPanelId
    }

    var hostDefaultCommandPortKickReason: PortScanKickReason {
        .command
    }

    func hostSyncRemotePortScanTTYs() {
        syncRemotePortScanTTYs()
    }

    func hostKickRemotePortScan(panelId: UUID, reason: PortScanKickReason) {
        kickRemotePortScan(panelId: panelId, reason: reason)
    }
}
