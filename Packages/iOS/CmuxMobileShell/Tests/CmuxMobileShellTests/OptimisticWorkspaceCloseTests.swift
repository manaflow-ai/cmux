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
        store.selectedTerminalID = "terminal-build"

        store.applyOptimisticWorkspaceClose(id: "workspace-main")

        #expect(store.selectedWorkspaceID == "workspace-docs")
        #expect(store.selectedTerminalID == "terminal-notes")
    }

    /// Closing a workspace that is not present is a no-op and records nothing.
    @Test func optimisticCloseOfMissingWorkspaceIsNoop() {
        let store = MobileShellComposite.preview()

        let removed = store.applyOptimisticWorkspaceClose(id: "workspace-missing")

        #expect(!removed)
        #expect(store.workspaces.count == 2)
        #expect(store.optimisticallyClosedWorkspaces.isEmpty)
    }

    /// The optimistic hide stays active only when the host explicitly confirms
    /// that it actually closed the workspace.
    @Test func closeResponseRequiresExplicitClosedTrue() throws {
        let store = MobileShellComposite.preview()

        #expect(store.workspaceCloseResponseConfirmsClosed(try jsonData(["closed": true])))
        #expect(!store.workspaceCloseResponseConfirmsClosed(try jsonData(["closed": false])))
        #expect(!store.workspaceCloseResponseConfirmsClosed(try jsonData(["workspace_id": "workspace-main"])))
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

    /// If the Mac rejects closing the selected workspace, rollback must restore
    /// selection to that workspace even though optimistic close already selected a
    /// neighbor.
    @Test func rollbackRestoresSelectedRejectedClose() {
        let store = MobileShellComposite.preview()
        store.selectedWorkspaceID = "workspace-main"
        store.selectedTerminalID = "terminal-build"
        store.applyOptimisticWorkspaceClose(id: "workspace-main")

        #expect(store.selectedWorkspaceID == "workspace-docs")

        store.rollbackOptimisticWorkspaceClose(id: "workspace-main")

        #expect(store.selectedWorkspaceID == "workspace-main")
        #expect(store.selectedTerminalID == "terminal-build")
    }

    /// If the user selects another workspace while the close RPC is in flight,
    /// rollback must not steal selection back to the rejected workspace.
    @Test func rollbackPreservesUserSelectionAfterRejectedClose() {
        let store = MobileShellComposite.preview()
        store.setWorkspacesForTesting([
            makeWorkspace(id: "workspace-main", macDeviceID: "mac-a"),
            makeWorkspace(id: "workspace-docs", macDeviceID: "mac-a"),
            makeWorkspace(id: "workspace-other", macDeviceID: "mac-a"),
        ])
        store.selectedWorkspaceID = "workspace-main"
        store.applyOptimisticWorkspaceClose(id: "workspace-main")
        store.selectedWorkspaceID = "workspace-other"

        store.rollbackOptimisticWorkspaceClose(id: "workspace-main")

        #expect(store.selectedWorkspaceID == "workspace-other")
    }

    /// If the Mac rejects closing the last remaining selected workspace, rollback
    /// must restore selection too so the detail view does not stay blank.
    @Test func rollbackRestoresSelectionWhenLastWorkspaceCloseIsRejected() {
        let store = MobileShellComposite.preview()
        store.applyOptimisticWorkspaceClose(id: "workspace-docs")
        store.selectedWorkspaceID = "workspace-main"
        store.applyOptimisticWorkspaceClose(id: "workspace-main")

        #expect(store.selectedWorkspaceID == nil)

        store.rollbackOptimisticWorkspaceClose(id: "workspace-main")

        #expect(store.selectedWorkspaceID == "workspace-main")
        #expect(store.workspaces.map(\.id.rawValue) == ["workspace-main"])
    }

    /// While a close is unconfirmed, a stale authoritative snapshot that still
    /// lists the workspace must not resurrect the row.
    @Test func staleSnapshotDoesNotResurrectPendingClose() throws {
        let store = MobileShellComposite.preview()
        store.applyOptimisticWorkspaceClose(id: "workspace-docs")

        // Mac has not yet processed the close, so its list still includes the row.
        let response = try makeListResponse(ids: ["workspace-main", "workspace-docs"])
        let reconciled = store.remoteWorkspacesPreservingSnapshots(from: response)

        #expect(reconciled.map(\.id.rawValue) == ["workspace-main", "workspace-docs"])
        store.setWorkspacesForTesting(reconciled)
        #expect(store.workspaces.map(\.id.rawValue) == ["workspace-main"])
        store.rollbackOptimisticWorkspaceClose(id: "workspace-docs")
        #expect(store.workspaces.map(\.id.rawValue) == ["workspace-main", "workspace-docs"])
        #expect(store.optimisticallyClosedWorkspaces.isEmpty)
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

    /// Scoped merge responses omit unrelated workspaces, so absence there must
    /// not be treated as close confirmation.
    @Test func partialSnapshotDoesNotRetirePendingClose() throws {
        let store = MobileShellComposite.preview()
        store.applyOptimisticWorkspaceClose(id: "workspace-docs")

        let response = try makeListResponse(ids: ["workspace-main"])
        _ = store.remoteWorkspacesPreservingSnapshots(
            from: response,
            authoritativeForPendingClosures: false
        )

        #expect(store.optimisticallyClosedWorkspaces.keys.contains("workspace-docs"))
    }

    /// Pending close filtering follows the Mac-local workspace id and owning Mac,
    /// not the derived row id, so aggregation row-id scoping changes cannot show a
    /// workspace while its close is still in flight.
    @Test func pendingCloseSurvivesAggregationRowIDShapeChange() {
        let store = MobileShellComposite.preview()
        let docs = makeWorkspace(id: "workspace-docs", macDeviceID: "mac-a")
        let main = makeWorkspace(id: "workspace-main", macDeviceID: "mac-a")
        store.setWorkspaceStatesForTesting(
            [
                "mac-a": MacWorkspaceState(
                    macDeviceID: "mac-a",
                    workspaces: [docs, main],
                    status: .connected
                ),
            ],
            foregroundMacDeviceID: "mac-a"
        )

        store.applyOptimisticWorkspaceClose(id: "workspace-docs")
        store.setWorkspaceStatesForTesting(
            [
                "mac-a": MacWorkspaceState(
                    macDeviceID: "mac-a",
                    workspaces: [docs, main],
                    status: .connected
                ),
                "mac-b": MacWorkspaceState(
                    macDeviceID: "mac-b",
                    workspaces: [makeWorkspace(id: "workspace-other", macDeviceID: "mac-b")],
                    status: .connected
                ),
            ],
            foregroundMacDeviceID: "mac-a"
        )

        #expect(!store.workspaces.contains {
            $0.rpcWorkspaceID == "workspace-docs" && $0.macDeviceID == "mac-a"
        })
        #expect(store.optimisticallyClosedWorkspaces.keys.contains("workspace-docs"))
    }

    /// Group metadata is derived from the same optimistically filtered workspace
    /// list, so closing an anchor cannot leave a stale navigable group header.
    @Test func optimisticClosePrunesGroupAnchoredByClosedWorkspace() {
        let store = MobileShellComposite.preview()
        store.setWorkspacesForTesting(
            [
                makeWorkspace(id: "workspace-docs", macDeviceID: "mac-a"),
                makeWorkspace(id: "workspace-main", macDeviceID: "mac-a"),
            ],
            groups: [
                MobileWorkspaceGroupPreview(
                    id: "group-docs",
                    name: "Docs",
                    anchorWorkspaceID: "workspace-docs"
                ),
            ]
        )

        store.applyOptimisticWorkspaceClose(id: "workspace-docs")

        #expect(!store.workspaces.contains { $0.id == "workspace-docs" })
        #expect(store.workspaceGroups.isEmpty)
    }

    /// Secondary full-list refreshes are authoritative for that Mac and must
    /// retire a pending close once the closed remote id disappears.
    @Test func secondarySnapshotRetiresPendingCloseForThatMac() throws {
        let store = MobileShellComposite.preview()
        var snapshot = MobileWorkspacePreview(
            id: "mac-b\u{1F}workspace-docs",
            macDeviceID: "mac-b",
            name: "Docs",
            terminals: []
        )
        snapshot.remoteWorkspaceID = "workspace-docs"
        store.optimisticallyClosedWorkspaces[snapshot.id] = snapshot

        let response = try makeListResponse(ids: ["workspace-main"])
        store.reconcileOptimisticClosures(against: response, macDeviceID: "mac-b")

        #expect(store.optimisticallyClosedWorkspaces.isEmpty)
    }

    /// An anonymous foreground refresh is authoritative only for ownerless rows, so
    /// it must not confirm a pending close that belongs to a secondary Mac.
    @Test func anonymousSnapshotDoesNotRetireSecondaryPendingClose() throws {
        let store = MobileShellComposite.preview()
        var snapshot = MobileWorkspacePreview(
            id: "mac-b\u{1F}workspace-docs",
            macDeviceID: "mac-b",
            name: "Docs",
            terminals: []
        )
        snapshot.remoteWorkspaceID = "workspace-docs"
        store.optimisticallyClosedWorkspaces[snapshot.id] = snapshot

        let response = try makeListResponse(ids: ["workspace-main"])
        store.reconcileOptimisticClosures(against: response, macDeviceID: nil)

        #expect(store.optimisticallyClosedWorkspaces.keys.contains(snapshot.id))
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

    private func makeWorkspace(
        id: MobileWorkspacePreview.ID,
        macDeviceID: String
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: id,
            macDeviceID: macDeviceID,
            name: id.rawValue,
            terminals: [
                MobileTerminalPreview(
                    id: MobileTerminalPreview.ID(rawValue: "\(id.rawValue)-terminal"),
                    name: "Terminal",
                    isFocused: true
                ),
            ]
        )
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
