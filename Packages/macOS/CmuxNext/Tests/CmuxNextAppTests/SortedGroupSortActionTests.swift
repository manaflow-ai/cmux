import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Review of #40676: Sort Workspaces changes the model first (the optimistic order) and then places the rows in the
/// sidebar document. A group with a document sort (Name) shows its sort, not the stored order, so a placement that
/// changes no shown row (the second Sort by Last Used: the stored order is that order already) left the optimistic
/// order in the model: `SidebarBridge.place` ended in a rows pass that skips equal rows, where `resync()` set the
/// model each time. The rows must show what the document shows in the same turn as the action.
@MainActor @Suite(.serialized) struct SortedGroupSortActionTests {
    static let session = "s-local"
    static let section = "sec_m_s-local"
    /// Key and name of each workspace, in the document's stored order (not the name order).
    static let stored = ["mike", "zulu", "alpha"]
    static let byName = ["alpha", "mike", "zulu"]

    static func documentData() -> Data {
        let orders = ["a", "b", "c"]
        let items = stored.enumerated().map { index, key in
            #"{"id": "w_\#(key)", "section": "\#(section)", "parent": "g_sorted", "order": "\#(orders[index])", "body": {"type": "workspace", "ref": {"session_id": "\#(session)", "workspace_id": "\#(key)"}}}"#
        }
        let group = #"{"id": "g_sorted", "section": "\#(section)", "order": "a", "body": {"type": "group", "name": "Sorted"}, "extra": {"sort": "name"}}"#
        return Data(#"{"revision": "1", "sections": [{"id": "\#(section)", "kind": {"type": "machine", "session_id": "\#(session)"}}], "items": [\#(([group] + items).joined(separator: ","))]}"#.utf8)
    }

    /// The names the window's one group lists, in order.
    static func shown(_ bridge: SidebarBridge) -> [String] {
        for case let .group(group) in bridge.model.sections.flatMap(\.nodes) { return group.workspaces.map(\.id.rawValue) }
        return []
    }

    /// The members of the document's one group, in the stored order.
    static func placed(_ document: SidebarDocStore) -> [String] {
        for case let .group(group) in document.shown?.machines[session] ?? [] { return group.members.map(\.workspaceID) }
        return []
    }

    @Test(.timeLimit(.minutes(5)))
    func sortByLastUsedOnAGroupSortedByNameLeavesTheGroupInItsSort() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let windows = services.windows
        windows.ordersWindowsIn = false
        _ = services.sidebarLayout
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        var tree = DaemonTree(registryID: Self.session, workspaces: Self.stored.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key),
                              resourceID: ResourceID(rawValue: key), name: key)
        })
        tree.personal = PersonalState(workspaces: Self.stored.enumerated().map { index, key in
            PersonalWorkspace(sessionID: Self.session, workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        store.apply(snapshot: tree)
        let document = SidebarDocStore(remote: SidebarGroupDragRailTests.Remote(document: Self.documentData()))
        services.sidebarDoc.store = document
        document.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(20)) { document.isActive }
        try #require(document.isActive, "fixture: the sidebar document did not load")
        document.show(live: services.sidebarDoc.docMachines.liveRefs())
        // The window shows "zulu": Sort by Last Used lists it first, which is not the name order.
        let controller = try #require(windows.openWindow(workspaces: ["zulu", "mike", "alpha"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        defer { controller.teardown(); controller.window?.close() }
        windows.didActivate(controller)
        for _ in 0..<50 where controller.workspaceContent == nil { await LargeSessionWindowFixture.drainMain() }
        if controller.state.workspaceID != "zulu" { controller.state.workspaceID = "zulu" }
        await LargeSessionWindowFixture.drainMain()
        document.show(live: services.sidebarDoc.docMachines.liveRefs())
        let bridge = controller.sidebar
        bridge.sameTurn.syncNow(rows: true)
        await LargeSessionWindowFixture.drainMain()

        // The fixture: the active window's rows are on the document, and its group shows the name order.
        try #require(windows.active === controller, "fixture: the window is not the active one")
        try #require(services.sidebarDoc.isActive && services.sidebarDoc.store === document && bridge.model.docDrag != nil,
                     "fixture: the window's rows are not on the sidebar document")
        try #require(Self.placed(document) == Self.stored, "fixture: the document stores \(Self.placed(document))")
        try #require(Self.shown(bridge) == Self.byName, "fixture: the group sorted by name shows \(Self.shown(bridge))")
        // What Sort by Last Used makes of the group: the shown workspace first, so not the name order.
        let lastUsed = WorkspaceSortKey.lastUsed.sorted(Self.byName, names: [:], directories: [:], recency: controller.state.workspaceRecency)
        try #require(lastUsed != Self.byName && lastUsed != Self.stored, "fixture: the last-used order is \(lastUsed) (recency \(controller.state.workspaceRecency))")

        // No await from here: each check is in the same turn as its action.
        // First sort: the stored order changes, the group keeps its sort.
        #expect(services.registry.perform("workspace.sortByLastUsed", invocation: ActionInvocation(origin: .user)))
        try #require(Self.placed(document) == lastUsed,
                     "the path under test did not run: the document stores \(Self.placed(document)) after Sort by Last Used")
        #expect(Self.shown(bridge) == Self.byName, "after the first sort the group sorted by name shows \(Self.shown(bridge))")
        // Second sort: the stored order is the last-used order already, so the placement changes no row. The
        // optimistic order must not stay.
        #expect(services.registry.perform("workspace.sortByLastUsed", invocation: ActionInvocation(origin: .user)))
        #expect(Self.placed(document) == lastUsed, "the second sort changed the stored order: \(Self.placed(document))")
        #expect(Self.shown(bridge) == Self.byName,
                "after the second sort the group sorted by name shows \(Self.shown(bridge)): the optimistic order stayed, which no store holds")
    }
}
