import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-19 on nightly fc1d07a: "adding and removing groups doesn't work" and "adding new tabs
/// from the group plus icon doesn't work". With the sidebar document (sidebar-v2, `sidebar-doc-v1`) the
/// sidebar shows each group under its document item id: a group from the personal store is the item
/// `itm_g_<group id>` (cmux-tui `group_item_id`). A group header's +, its editor's rows (Delete,
/// Ungroup, Close) and its menu target that item id, and every group action looked it up as a personal
/// group id: none matched, so each was refused with "That workspace group no longer exists".
@MainActor @Suite(.serialized)
struct SidebarDocGroupTargetTests {
    static func context() -> AppActionContext {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        var tree = DaemonTree(registryID: "s-local")
        tree.personal = PersonalState(groups: [
            WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: "g1"), name: "web", profile: .defaultProfile),
            WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: "doc-made"), name: "made on the document", index: 1, profile: .defaultProfile),
        ])
        services.machines.local.store.apply(snapshot: tree)
        return AppActionContext(services: services)
    }

    static func target(_ id: String) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .workspaceGroup, id: id))
    }

    /// The header's +, Delete Group and the rest name the group by the item the sidebar shows.
    @Test func aGroupActionFindsThePersonalGroupBehindItsDocumentItem() throws {
        let context = Self.context()
        #expect(try context.group(Self.target("itm_g_g1")).id.rawValue == "g1")
    }

    /// A group the document made keeps one id in both stores; a personal id still resolves (CLI, MCP).
    @Test func plainIDsStillResolve() throws {
        let context = Self.context()
        #expect(try context.group(Self.target("doc-made")).id.rawValue == "doc-made")
        #expect(try context.group(Self.target("g1")).id.rawValue == "g1")
        #expect(throws: ActionFailure.self) { try context.group(Self.target("itm_g_gone")) }
    }
}

/// The other way: an action resolves a personal group and edits the group the sidebar shows, so it must
/// name the group by the id the sidebar shows it under (its document item on sidebar-v2).
@MainActor @Suite
struct SidebarDocShownGroupIDTests {
    static func model() -> CmuxNextSidebar.SidebarModel {
        CmuxNextSidebar.SidebarModel(sections: [
            CmuxNextSidebar.SidebarSection(kind: .machine(CmuxNextSidebar.SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
                .group(CmuxNextSidebar.SidebarGroup(id: CmuxNextSidebar.GroupID("itm_g_g1"), name: "migrated", workspaces: [])),
                .group(CmuxNextSidebar.SidebarGroup(id: CmuxNextSidebar.GroupID("doc-made"), name: "made on the document", workspaces: [])),
            ]),
        ], activeWorkspaceID: nil)
    }

    @Test func aPersonalGroupIsNamedByTheItemTheSidebarShows() {
        let model = Self.model()
        #expect(model.groupID(personal: "g1") == CmuxNextSidebar.GroupID("itm_g_g1"))
        #expect(model.groupID(personal: "doc-made") == CmuxNextSidebar.GroupID("doc-made"))
        #expect(model.groupID(personal: "not-shown") == CmuxNextSidebar.GroupID("not-shown"))
    }

    /// Next/Previous Workspace Group start from the group the active workspace is in, by its personal id:
    /// compared with the sidebar's `itm_g_g1`, no room group matched and the walk always began at an end.
    @Test func theActiveGroupIsNamedByItsPersonalID() {
        let row = CmuxNextSidebar.SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("w1"), title: "w1")
        let model = CmuxNextSidebar.SidebarModel(sections: [
            CmuxNextSidebar.SidebarSection(kind: .machine(CmuxNextSidebar.SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
                .group(CmuxNextSidebar.SidebarGroup(id: CmuxNextSidebar.GroupID("doc-made"), name: "made on the document", workspaces: [])),
                .group(CmuxNextSidebar.SidebarGroup(id: CmuxNextSidebar.GroupID("itm_g_g1"), name: "migrated", workspaces: [row])),
            ]),
        ], activeWorkspaceID: row.id)
        #expect(model.activeGroupPersonalID == "g1")
        #expect(Self.model().activeGroupPersonalID == nil)
    }

    @Test func itemIDsMapBackToPersonalIDs() {
        #expect(SidebarDocStore.personalGroupID(item: "itm_g_g1") == "g1")
        #expect(SidebarDocStore.personalGroupID(item: "doc-made") == "doc-made")
    }
}

/// The header's + (SidebarListView+Reuse `onAdd`) and the group editor's rows reach the registry through
/// `onGroupEditorItem` with the group the sidebar shows (`itm_g_g1` on the sidebar document); the action
/// must get the personal group id the personal store and `workspaceGroup.newWorkspace` place into.
@MainActor @Suite(.serialized)
struct SidebarDocGroupEditorTargetTests {
    @Test func theHeaderPlusTargetsThePersonalGroup() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"plus","workspace_key":"plus-home"}"#.utf8))
        let bridge = SidebarBridge(services: services, state: WindowState(record: record))
        var targets: [String] = []
        // Bound outside #expect: its autoclosure is @Sendable and cannot capture the mutable `targets`.
        let bound = services.registry.bind("workspaceGroup.newWorkspace", invoke: { invocation in targets.append(invocation.target?.id ?? "") })
        #expect(bound)
        let perform = try #require(bridge.container.onGroupEditorItem)
        perform(CmuxNextSidebar.GroupID("itm_g_g1"), "workspaceGroup.newWorkspace")
        perform(CmuxNextSidebar.GroupID("doc-made"), "workspaceGroup.newWorkspace")
        #expect(targets == ["g1", "doc-made"])
    }
}
