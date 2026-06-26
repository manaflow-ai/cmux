import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

// Regression coverage for issue #6349: on iOS, a confirmed workspace delete must
// remove the workspace AND its sidebar row atomically, and a lagging/stale
// `workspace.list` response (the Mac removes the workspace synchronously before
// acking the close, but the immediate re-sync — or a `workspace.updated` refresh
// already in flight against a pre-close snapshot — can still observe the old
// list) must never resurrect the deleted row.
//
// The scripted Mac here models the worst case: `workspace.close` succeeds, yet
// every `workspace.list` keeps returning BOTH workspaces (the list never catches
// up within the test). A correct client drops the row on the confirmed close and
// keeps it dropped; a buggy client re-adds it from the stale list.

// MARK: - Scripted Mac for the close/reconcile race

private actor CloseReconcileHostRouter {
    private(set) var closeRequestCount = 0
    /// Once set, `workspace.list` stops reporting the closed workspace — the Mac's
    /// authoritative list has caught up, which should retire the close tombstone.
    private var caughtUp = false
    func markCaughtUp() { caughtUp = true }
    private let capabilities = [
        "events.v1",
        "workspace.actions.v1",
        "workspace.read_state.v1",
        "workspace.close.v1",
        "terminal.render_grid.v1",
        "terminal.replay.v1",
    ]

    func response(method: String?, id: String?) async -> Data? {
        switch method {
        case "workspace.list", "mobile.workspace.list":
            // Returns BOTH workspaces (the stale snapshot that drives the bug) until
            // the Mac "catches up" and drops the closed one.
            return try? Self.resultFrame(id: id, result: ["workspaces": Self.workspaceList(includeClosed: !caughtUp)])
        case "workspace.close":
            closeRequestCount += 1
            return try? Self.resultFrame(id: id, result: [
                "closed": true,
                "workspace_id": "live-workspace",
            ])
        case "mobile.host.status":
            return try? Self.resultFrame(id: id, result: [
                "terminal_fidelity": "render_grid",
                "capabilities": capabilities,
            ])
        case "mobile.events.subscribe":
            return try? Self.resultFrame(id: id, result: [
                "stream_id": "test-stream",
                "topics": ["workspace.updated", "terminal.render_grid"],
                "already_subscribed": false,
            ])
        case "mobile.events.unsubscribe", "mobile.terminal.replay", "mobile.terminal.viewport":
            return try? Self.resultFrame(id: id, result: [:])
        default:
            return try? Self.errorFrame(id: id, message: "Unexpected method \(method ?? "nil")")
        }
    }

    private static func workspaceList(includeClosed: Bool) -> [[String: Any]] {
        var list = [workspaceEntry(id: "workspace-b", title: "Workspace B", selected: true, terminalID: "terminal-b")]
        if includeClosed {
            list.insert(
                workspaceEntry(id: "live-workspace", title: "Workspace A", selected: false, terminalID: "live-terminal"),
                at: 0)
        }
        return list
    }

    private static func workspaceEntry(
        id: String,
        title: String,
        selected: Bool,
        terminalID: String
    ) -> [String: Any] {
        [
            "id": id,
            "title": title,
            "current_directory": "/Users/test/project",
            "is_selected": selected,
            "terminals": [
                [
                    "id": terminalID,
                    "title": "Terminal",
                    "current_directory": "/Users/test/project",
                    "is_ready": true,
                    "is_focused": selected,
                ],
            ],
        ]
    }

    private static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }

    private static func errorFrame(id: String?, message: String) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": false,
            "error": ["message": message],
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}

private struct CloseReconcileTransportFactory: CmxByteTransportFactory {
    let router: CloseReconcileHostRouter

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        CloseReconcileTransport(router: router)
    }
}

private actor CloseReconcileTransport: CmxByteTransport {
    private let router: CloseReconcileHostRouter
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(router: CloseReconcileHostRouter) {
        self.router = router
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let method = parsed?["method"] as? String
            let id = parsed?["id"] as? String
            Task { [router, weak self] in
                guard let response = await router.response(method: method, id: id) else { return }
                await self?.deliver(response)
            }
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(returning: frame)
    }
}

@MainActor
private func makeConnectedCloseStore(
    router: CloseReconcileHostRouter,
    clock: TestClock
) async throws -> MobileShellComposite {
    let runtime = LivenessTestRuntime(
        transportFactory: CloseReconcileTransportFactory(router: router),
        now: { clock.now }
    )
    let store = MobileShellComposite.preview(runtime: runtime)
    store.signIn()
    let ticket = try makeTicket(clock: clock)
    let connected = await store.connectPairingURL(try attachURL(for: ticket))
    #expect(connected, "scripted connect must succeed")
    return store
}

// MARK: - Tests

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
