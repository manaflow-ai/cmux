import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

// Regression coverage for issue #6349: on iOS, a confirmed workspace delete must
// remove the workspace AND its sidebar row atomically, and a lagging/stale
// `workspace.list` response (the Mac removes the workspace synchronously before
// acking the close, but the immediate re-sync — or a `workspace.updated` refresh
// already in flight against a pre-close snapshot — can still observe the old
// list) must never resurrect the deleted row.
//
// The scripted Mac fixtures live in MobileWorkspaceCloseReconcileTestSupport.swift.

@MainActor
struct MobileWorkspaceCloseReconcileTests {
    private let liveWorkspaceID = MobileWorkspacePreview.ID(rawValue: "live-workspace")
    private let neighborWorkspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-b")

    /// A confirmed close drops the row immediately and a stale `workspace.list`
    /// that still includes the closed workspace must not bring it back.
    @Test func confirmedCloseDropsStaleSidebarRow() async throws {
        let router = CloseReconcileHostRouter()
        let clock = TestClock()
        let store = try await makeConnectedCloseStore(router: router, clock: clock)

        // Wait for the list AND the host.status capability resolution that stamps
        // `supportsCloseActions` onto the rows (a separate async step from the list
        // arriving); closeWorkspace is a no-op until the row advertises it.
        #expect(try await pollUntil {
            store.workspaces.count == 2
                && (store.workspaces.first { $0.id == liveWorkspaceID }?
                    .actionCapabilities.supportsCloseActions ?? false)
        })
        #expect(store.workspaces.contains { $0.id == liveWorkspaceID })

        await store.closeWorkspace(id: liveWorkspaceID)

        // The Mac confirmed the close; the row is gone even though the scripted
        // `workspace.list` re-sync (awaited inside closeWorkspace) still lists it.
        #expect(await router.closeRequestCount == 1)
        #expect(!store.workspaces.contains { $0.id == liveWorkspaceID })
        #expect(store.workspaces.contains { $0.id == neighborWorkspaceID })
        #expect(store.workspaces.count == 1)

        // A later explicit refresh, again served the stale two-workspace list,
        // must keep the deleted row dropped.
        await store.refreshWorkspaces()
        #expect(!store.workspaces.contains { $0.id == liveWorkspaceID })
        #expect(store.workspaces.count == 1)
    }

    /// The close tombstone only bridges the stale-refresh window: once the Mac's
    /// authoritative list stops reporting the closed workspace, the next refresh
    /// retires the tombstone so it can't accumulate or suppress a future row
    /// (issue #6349, tombstone lifecycle).
    @Test func tombstoneClearsOnceMacListCatchesUp() async throws {
        let router = CloseReconcileHostRouter()
        let clock = TestClock()
        let store = try await makeConnectedCloseStore(router: router, clock: clock)

        #expect(try await pollUntil {
            store.workspaces.count == 2
                && (store.workspaces.first { $0.id == liveWorkspaceID }?
                    .actionCapabilities.supportsCloseActions ?? false)
        })
        await store.closeWorkspace(id: liveWorkspaceID)
        // Tombstoned while the Mac's list still reports the closed row.
        #expect(store.confirmedClosedWorkspaceIDsByMac.values.contains { $0.contains("live-workspace") })

        // Mac catches up; the next authoritative refresh must retire the tombstone.
        await router.markCaughtUp()
        await store.refreshWorkspaces()
        #expect(!store.workspaces.contains { $0.id == liveWorkspaceID })
        #expect(!store.confirmedClosedWorkspaceIDsByMac.values.contains { $0.contains("live-workspace") })
    }

    /// `closeWorkspace` can target a SECONDARY Mac, whose refresh writes that Mac's
    /// `workspacesByMac` entry directly. The tombstone filter lives at the single
    /// derivation chokepoint, so a stale secondary re-list of a confirmed-closed
    /// workspace is dropped just like a foreground one — AND because tombstones are
    /// scoped to the owning Mac, a different Mac's workspace that happens to share
    /// the same Mac-local id is left untouched (issue #6349, secondary path +
    /// multi-Mac id collision). Seeds the per-Mac source of truth directly so no
    /// live secondary connection is needed.
    @Test func confirmedCloseTombstoneIsScopedToOwningMac() {
        let store = MobileShellComposite.preview()
        // Only Mac B's copy of the shared local id was closed.
        store.confirmedClosedWorkspaceIDsByMac = ["mac-b": ["shared-id"]]
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a", displayName: "Mac A",
                workspaces: [Self.preview(id: "shared-id"), Self.preview(id: "mac-a-only")],
                status: .connected),
            // Secondary Mac still lists the just-closed workspace (the stale snapshot).
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b", displayName: "Mac B",
                workspaces: [Self.preview(id: "shared-id"), Self.preview(id: "mac-b-only")],
                status: .connected),
        ], foregroundMacDeviceID: "mac-a")

        func has(mac: String, rpc: String) -> Bool {
            store.workspaces.contains { $0.macDeviceID == mac && $0.rpcWorkspaceID.rawValue == rpc }
        }
        #expect(!has(mac: "mac-b", rpc: "shared-id"))   // closed row gone
        #expect(has(mac: "mac-a", rpc: "shared-id"))    // same id on another Mac survives
        #expect(has(mac: "mac-b", rpc: "mac-b-only"))
        #expect(has(mac: "mac-a", rpc: "mac-a-only"))
    }

    /// A confirmed-closed workspace that anchors a group must also drop the stale
    /// group header (the Mac dissolves the group when its anchor closes), so the
    /// deleted row can't linger as a header that still targets the dead anchor id.
    /// Surviving members degrade to ungrouped rows (issue #6349, grouped UI).
    @Test func confirmedCloseDissolvesStaleGroupHeader() {
        let store = MobileShellComposite.preview()
        let groupID = MobileWorkspaceGroupPreview.ID(rawValue: "group-1")
        store.confirmedClosedWorkspaceIDsByMac = ["mac-a": ["anchor-ws"]]
        store.setWorkspaceStatesForTesting([
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a", displayName: "Mac A",
                workspaces: [
                    Self.preview(id: "anchor-ws", groupID: groupID),
                    Self.preview(id: "member-ws", groupID: groupID),
                ],
                groups: [
                    MobileWorkspaceGroupPreview(
                        id: groupID, name: "Group", anchorWorkspaceID: .init(rawValue: "anchor-ws")),
                ],
                status: .connected),
        ], foregroundMacDeviceID: "mac-a")

        // Closed anchor gone from the flat list AND its stale group header is gone.
        #expect(!store.workspaces.contains { $0.rpcWorkspaceID.rawValue == "anchor-ws" })
        #expect(!store.workspaceGroups.contains { $0.anchorWorkspaceID.rawValue == "anchor-ws" })
        // The surviving member stays (renders ungrouped once its group is gone).
        #expect(store.workspaces.contains { $0.rpcWorkspaceID.rawValue == "member-ws" })
    }

    private static func preview(
        id: String, groupID: MobileWorkspaceGroupPreview.ID? = nil
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(id: .init(rawValue: id), name: id, groupID: groupID, terminals: [])
    }
}
