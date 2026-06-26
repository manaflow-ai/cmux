import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the optimistic workspace swipe-to-delete path (issue #6348):
/// the row is removed from the list immediately, selection reconciles to a
/// neighbor, and the row rolls back to its original position when the backend
/// close cannot be delivered. These drive the real ``MobileShellComposite`` source
/// of truth without a live transport.
@MainActor
@Suite struct WorkspaceOptimisticCloseTests {
    /// Seed a single foreground Mac whose rows support close, so derived ids equal
    /// the seeded ids (no aggregate scoping with one Mac).
    private func makeStore(ids: [String], selected: String?) -> MobileShellComposite {
        let store = MobileShellComposite.preview()
        store.signIn()
        let workspaces = ids.map {
            MobileWorkspacePreview(id: .init(rawValue: $0), macDeviceID: "mac-a", name: $0, terminals: [])
        }
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: workspaces,
                status: .connected,
                actionCapabilities: .init(supportsCloseActions: true)
            ),
        ], foregroundMacDeviceID: "mac-a")
        store.selectedWorkspaceID = selected.map { .init(rawValue: $0) }
        return store
    }

    @Test func optimisticRemovalDropsRowImmediatelyAndPicksNeighbor() throws {
        let store = makeStore(ids: ["A", "B", "C"], selected: "B")

        let rollback = store.removeWorkspaceOptimistically(id: "B")

        // The row is gone from the published list right away — no wait on a backend
        // close — and a snapshot was returned for rollback.
        #expect(store.workspaces.map(\.id.rawValue) == ["A", "C"])
        #expect(rollback != nil)
        // Deleting the selected workspace never leaves a blank selection: it lands on
        // a still-present neighbor, not the removed row.
        let selected = try #require(store.selectedWorkspaceID)
        #expect(selected.rawValue != "B")
        #expect(store.workspaces.contains { $0.id == selected })
    }

    @Test func restoreReinsertsRemovedRowAtOriginalIndex() throws {
        let store = makeStore(ids: ["A", "B", "C"], selected: "A")

        let rollback = try #require(store.removeWorkspaceOptimistically(id: "B"))
        #expect(store.workspaces.map(\.id.rawValue) == ["A", "C"])

        store.restoreWorkspace(rollback)

        // The row comes back exactly where it was, preserving order.
        #expect(store.workspaces.map(\.id.rawValue) == ["A", "B", "C"])
    }

    @Test func restoreIsNoOpWhenRowAlreadyReappeared() throws {
        let store = makeStore(ids: ["A", "B", "C"], selected: "A")
        let rollback = try #require(store.removeWorkspaceOptimistically(id: "B"))

        // An authoritative refresh re-adds B before the late failure rollback runs.
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: ["A", "B", "C"].map {
                    MobileWorkspacePreview(id: .init(rawValue: $0), macDeviceID: "mac-a", name: $0, terminals: [])
                },
                status: .connected,
                actionCapabilities: .init(supportsCloseActions: true)
            ),
        ], foregroundMacDeviceID: "mac-a")

        store.restoreWorkspace(rollback)

        // Rollback must not duplicate the already-present row.
        #expect(store.workspaces.map(\.id.rawValue) == ["A", "B", "C"])
    }

    @Test func removeOptimisticallyReturnsNilForUnknownID() {
        let store = makeStore(ids: ["A", "B"], selected: "A")

        let rollback = store.removeWorkspaceOptimistically(id: "missing")

        #expect(rollback == nil)
        #expect(store.workspaces.map(\.id.rawValue) == ["A", "B"])
    }

    /// Two Macs make the aggregate scope row ids, so the derived id no longer equals
    /// the raw per-Mac id. Removal must still resolve the scoped row back to the
    /// owning secondary Mac's workspace.
    @Test func optimisticRemovalResolvesScopedRowToOwningMac() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [MobileWorkspacePreview(id: "wsa", macDeviceID: "mac-a", name: "A", terminals: [])],
                status: .connected,
                actionCapabilities: .init(supportsCloseActions: true)
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [MobileWorkspacePreview(id: "wsb", macDeviceID: "mac-b", name: "B", terminals: [])],
                status: .connected,
                actionCapabilities: .init(supportsCloseActions: true)
            ),
        ], foregroundMacDeviceID: "mac-a")

        let derivedB = try #require(store.workspaces.first { $0.rpcWorkspaceID.rawValue == "wsb" })
        // Confirm the derived id is genuinely scoped (not the raw "wsb").
        #expect(derivedB.id.rawValue != "wsb")

        let rollback = try #require(store.removeWorkspaceOptimistically(id: derivedB.id))

        #expect(rollback.macKey == "mac-b")
        #expect(!store.workspaces.contains { $0.rpcWorkspaceID.rawValue == "wsb" })
        #expect(store.workspaces.contains { $0.rpcWorkspaceID.rawValue == "wsa" })

        store.restoreWorkspace(rollback)
        #expect(store.workspaces.contains { $0.rpcWorkspaceID.rawValue == "wsb" })
    }

    /// End-to-end of the public close path: a row owned by a secondary Mac with no
    /// live connection cannot be delivered, so the optimistic removal must roll back
    /// and leave the row in place rather than dropping it.
    @Test func closeWorkspaceRollsBackWhenUndeliverable() async throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                workspaces: [MobileWorkspacePreview(id: "wsa", macDeviceID: "mac-a", name: "A", terminals: [])],
                status: .connected,
                actionCapabilities: .init(supportsCloseActions: true)
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [MobileWorkspacePreview(id: "wsb", macDeviceID: "mac-b", name: "B", terminals: [])],
                status: .connected,
                actionCapabilities: .init(supportsCloseActions: true)
            ),
        ], foregroundMacDeviceID: "mac-a")
        let derivedB = try #require(store.workspaces.first { $0.rpcWorkspaceID.rawValue == "wsb" })

        await store.closeWorkspace(id: derivedB.id)

        // No live secondary connection means the close never lands; the row returns.
        #expect(store.workspaces.contains { $0.rpcWorkspaceID.rawValue == "wsb" })
    }
}
