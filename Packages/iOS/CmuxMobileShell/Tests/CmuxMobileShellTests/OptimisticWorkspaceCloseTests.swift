import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the optimistic close path on ``MobileShellComposite``.
///
/// These exercise the in-memory state machine that makes a workspace close feel
/// instant: the row leaves the list immediately, a rejected close restores it,
/// and the reconciliation against an authoritative list keeps a stale snapshot
/// from resurrecting an in-flight close while still retiring a confirmed one.
@MainActor
@Suite struct OptimisticWorkspaceCloseTests {
    /// The optimistic removal drops the row from the local list right away and
    /// records its snapshot so a later rollback has something to restore.
    @Test func optimisticCloseRemovesRowImmediately() {
        let store = MobileShellComposite.preview()

        let removed = store.applyOptimisticWorkspaceClose(id: "workspace-docs")

        #expect(removed)
        #expect(store.workspaces.map(\.id.rawValue) == ["workspace-main"])
        #expect(store.optimisticallyClosedWorkspaces.keys.contains("workspace-docs"))
    }

    /// Closing the selected workspace reselects a remaining one so the detail view
    /// never points at a vanished id.
    @Test func optimisticCloseOfSelectedReselectsNeighbor() {
        let store = MobileShellComposite.preview()
        store.selectedWorkspaceID = "workspace-main"

        store.applyOptimisticWorkspaceClose(id: "workspace-main")

        #expect(store.selectedWorkspaceID == "workspace-docs")
    }

    /// Closing a workspace that is not present is a no-op and records nothing.
    @Test func optimisticCloseOfMissingWorkspaceIsNoop() {
        let store = MobileShellComposite.preview()

        let removed = store.applyOptimisticWorkspaceClose(id: "workspace-missing")

        #expect(!removed)
        #expect(store.workspaces.count == 2)
        #expect(store.optimisticallyClosedWorkspaces.isEmpty)
    }

    /// A failed close restores the removed row and clears the pending entry, so
    /// the next authoritative refresh treats the workspace as live again.
    @Test func rollbackRestoresRemovedRow() {
        let store = MobileShellComposite.preview()
        store.applyOptimisticWorkspaceClose(id: "workspace-docs")

        store.rollbackOptimisticWorkspaceClose(id: "workspace-docs")

        #expect(store.workspaces.contains { $0.id == "workspace-docs" })
        #expect(store.optimisticallyClosedWorkspaces.isEmpty)
    }

    /// While a close is unconfirmed, a stale authoritative snapshot that still
    /// lists the workspace must not resurrect the row.
    @Test func staleSnapshotDoesNotResurrectPendingClose() throws {
        let store = MobileShellComposite.preview()
        store.applyOptimisticWorkspaceClose(id: "workspace-docs")

        // Mac has not yet processed the close, so its list still includes the row.
        let response = try makeListResponse(ids: ["workspace-main", "workspace-docs"])
        let reconciled = store.remoteWorkspacesPreservingSnapshots(from: response)

        #expect(reconciled.map(\.id.rawValue) == ["workspace-main"])
        // Still pending: the close has not been confirmed by the Mac.
        #expect(store.optimisticallyClosedWorkspaces.keys.contains("workspace-docs"))
    }

    /// An authoritative snapshot that omits the workspace confirms the close, so
    /// the pending entry is retired and the id no longer needs filtering.
    @Test func confirmingSnapshotRetiresPendingClose() throws {
        let store = MobileShellComposite.preview()
        store.applyOptimisticWorkspaceClose(id: "workspace-docs")

        let response = try makeListResponse(ids: ["workspace-main"])
        let reconciled = store.remoteWorkspacesPreservingSnapshots(from: response)

        #expect(reconciled.map(\.id.rawValue) == ["workspace-main"])
        #expect(store.optimisticallyClosedWorkspaces.isEmpty)
    }

    private func makeListResponse(ids: [String]) throws -> MobileSyncWorkspaceListResponse {
        let workspaceObjects = ids.enumerated().map { index, id -> [String: Any] in
            [
                "id": id,
                "title": id,
                "is_selected": index == 0,
                "terminals": [
                    ["id": "\(id)-terminal", "title": "Term", "is_focused": true],
                ],
            ]
        }
        let payload: [String: Any] = ["workspaces": workspaceObjects]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try MobileSyncWorkspaceListResponse.decode(data)
    }
}
