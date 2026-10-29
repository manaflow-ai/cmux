import Foundation
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-23: "there is a lot of lag in terminal, when stuff in sidebar rearranges, we need to completely
/// get rid of this lag case from first principles". On the sidebar document the document orders every placed row; the
/// daemon's own workspace order only orders the live workspaces the document does not place yet. A workspace that
/// moves in the daemon's list (`workspace move --index 0`) changed the live list the store projects over, and
/// `SidebarDocStore.show` asked the reducer for every row again and rebuilt the projection of all 400 workspaces,
/// although nothing it draws had changed (sidebar-churn-typing.py: ~10% of the main thread while the sidebar churned).
/// A reorder of placed workspaces must cost no view call and no projection; what the store shows still equals a
/// projection built fresh after each change.
@MainActor @Suite(.serialized) struct SidebarDocReorderProjectionCostTests {
    static let session = "s1"
    static let section = "sec_m_s1"
    static let groups = 8, membersPerGroup = 45, loose = 40

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    /// A well-formed order key for position `index` (two base-62 digits, never ending in `0`).
    static func order(_ index: Int) -> String {
        let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return String([digits[1 + index / 61], digits[1 + index % 61]])
    }

    /// The placed workspaces: `loose` loose ones, then `groups` groups of `membersPerGroup` (400 in all).
    static let placed: [String] = (0..<loose).map { "l\($0)" }
        + (0..<groups).flatMap { g in (0..<membersPerGroup).map { "g\(g)m\($0)" } }

    static func workspaceItem(_ id: String, order: Int, parent: String? = nil) -> String {
        let parentField = parent.map { #""parent": "\#($0)", "# } ?? ""
        return #"{"id": "w_\#(id)", "section": "\#(section)", \#(parentField)"order": "\#(Self.order(order))", "body": {"type": "workspace", "ref": {"session_id": "\#(session)", "workspace_id": "\#(id)"}}}"#
    }

    static let document: Data = {
        var items: [String] = []
        for i in 0..<loose { items.append(workspaceItem("l\(i)", order: i)) }
        for g in 0..<groups {
            items.append(#"{"id": "g_\#(g)", "section": "\#(section)", "order": "\#(order(loose + g))", "body": {"type": "group", "name": "Group \#(g)"}}"#)
            for m in 0..<membersPerGroup { items.append(workspaceItem("g\(g)m\(m)", order: m, parent: "g_\(g)")) }
        }
        let json = #"{"revision": "1", "sections": [{"id": "\#(section)", "kind": {"type": "machine", "session_id": "\#(session)"}}], "items": [\#(items.joined(separator: ","))]}"#
        return Data(json.utf8)
    }()

    static func loaded() async throws -> SidebarDocStore {
        let store = SidebarDocStore(remote: SidebarGroupDragRailTests.Remote(document: document))
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        return store
    }

    static var views: Int { SidebarMirror.calls["view"] ?? 0 }

    /// What the store shows equals a projection built fresh over the same live list.
    static func expectMatchesFreshProjection(_ store: SidebarDocStore, live: [SidebarDocWorkspaceRef], _ what: String) {
        let shown = store.shown
        store.projectionCache = nil
        let fresh = store.projection(live: live)
        #expect(shown == fresh, "\(what): the shown projection is not the one a fresh rebuild makes")
    }

    @Test func aDaemonReorderOfPlacedWorkspacesBuildsNoProjection() async throws {
        let store = try await Self.loaded()
        var live = Self.placed.map(Self.ref)
        store.show(live: live)
        let first = try #require(store.shown, "the store shows no projection")
        #expect(first.machines[Self.session]?.count == Self.loose + Self.groups)
        // Workspaces move in the daemon's list, as `workspace move --index 0` does: the document still orders them.
        for (from, to) in [(399, 0), (17, 0), (250, 3), (5, 380)] {
            live.insert(live.remove(at: from), at: to)
            let before = Self.views
            store.show(live: live)
            #expect(Self.views == before, "a reorder of placed workspaces asked the reducer for every row again")
            #expect(store.shown == first, "a reorder of placed workspaces changed what the sidebar shows")
            Self.expectMatchesFreshProjection(store, live: live, "after moving \(from) to \(to)")
        }
    }

    /// The daemon's order still orders the workspaces the document does not place yet (a new one, before its item).
    @Test func aReorderOfUnplacedWorkspacesStillShows() async throws {
        let store = try await Self.loaded()
        var live = Self.placed.map(Self.ref) + [Self.ref("new-a"), Self.ref("new-b")]
        store.show(live: live)
        #expect(store.shown?.unplaced == [Self.ref("new-a"), Self.ref("new-b")])
        live.swapAt(live.count - 1, live.count - 2)
        store.show(live: live)
        #expect(store.shown?.unplaced == [Self.ref("new-b"), Self.ref("new-a")])
        Self.expectMatchesFreshProjection(store, live: live, "after the unplaced rows swapped")
        // A placed workspace leaving the live set (closed) still rebuilds.
        live.removeAll { $0 == Self.ref("g3m7") }
        store.show(live: live)
        #expect(store.shown?.items[Self.ref("g3m7")] == nil)
        Self.expectMatchesFreshProjection(store, live: live, "after a close")
    }
}
