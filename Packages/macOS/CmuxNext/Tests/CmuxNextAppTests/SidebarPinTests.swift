@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSidebar
import Testing

/// Pinned workspaces (`workspace-pin-v1`) sit in a Pinned section at the top
/// of a window's sidebar, in sidebar order, like the old app's.
struct SidebarPinTests {
    static let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)

    static func workspace(_ id: String) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: id)
    }

    static let sections = [SidebarSection(kind: .machine(machine), nodes: [
        .workspace(workspace("a")),
        .group(SidebarGroup(id: GroupID("g"), name: "Agents", workspaces: [workspace("b"), workspace("c")])),
        .workspace(workspace("d")),
    ])]

    static func ids(_ section: SidebarSection) -> [String] {
        section.workspaces.map(\.id.rawValue)
    }

    @Test func pinnedWorkspacesMoveToATopSectionInSidebarOrder() {
        let result = SidebarMembership.pinnedFirst(Self.sections, pinned: ["d", "b"])
        #expect(result.count == 2)
        #expect(result[0].id == .pinned)
        #expect(Self.ids(result[0]) == ["b", "d"])
        #expect(Self.ids(result[1]) == ["a", "c"])
    }

    @Test func noPinNoPinnedSection() {
        let result = SidebarMembership.pinnedFirst(Self.sections, pinned: ["elsewhere"])
        #expect(result == Self.sections)
    }

    @Test func groupsStayWhenEmptyOrFullyPinned() {
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: [
            .workspace(Self.workspace("a")),
            .group(SidebarGroup(id: GroupID("empty"), name: "Empty", workspaces: [])),
            .group(SidebarGroup(id: GroupID("g"), name: "Agents", workspaces: [Self.workspace("b"), Self.workspace("c")])),
        ])]
        let result = SidebarMembership.pinnedFirst(sections, pinned: ["a", "b", "c"])
        #expect(Self.ids(result[0]) == ["a", "b", "c"])
        let groups = result[1].nodes.compactMap { node -> String? in
            if case let .group(group) = node { return group.id.rawValue }
            return nil
        }
        #expect(groups == ["empty", "g"])
        #expect(result[1].workspaces.isEmpty)
    }
}
