import AppKit
@testable import CmuxNextAgentLanes
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Testing

@MainActor struct SidebarSessionHostTests {
    private static let parent = WorkspaceID("parent"), child = WorkspaceID("child"), other = WorkspaceID("other")
    private static let host = "registry:build"

    private static func state(crossHost: Bool = false) -> SidebarSessionTreeState {
        let childHost = crossHost ? "registry:other" : host
        let chats = [(parent, [AgentSessionRef(host: host, hostName: "Build Mac", session: "coordinator")]),
                     (child, [AgentSessionRef(host: childHost, hostName: "Child Mac", session: "worker")])]
        let parents = [AgentSessionParents.identity(host: childHost, session: "worker"):
                       AgentSessionParents.identity(host: host, session: "coordinator")]
        return SidebarSessionTreeFeed.pass(chats, lanes: [:], recordedParents: parents,
                                          localHost: "install:local", pullRequests: [:]).state
    }

    private static func sections(parentPresent: Bool = true, crossMachine: Bool = false) -> [SidebarSection] {
        let parentRow = SidebarWorkspace(id: parent, title: "Coordinator")
        let childRow = SidebarWorkspace(id: child, title: "Worker")
        let unrelated = SidebarWorkspace(id: other, title: "Shell")
        let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        if crossMachine {
            let remote = SidebarMachine(id: MachineID("remote"), name: "Remote", kind: .ssh)
            return [SidebarSection(kind: .machine(local), nodes: parentPresent ? [.workspace(parentRow), .workspace(unrelated)] : [.workspace(unrelated)]),
                    SidebarSection(kind: .machine(remote), nodes: [.workspace(childRow)])]
        }
        return [SidebarSection(kind: .machine(local), nodes:
                    (parentPresent ? [.workspace(parentRow)] : []) + [.workspace(unrelated), .workspace(childRow)])]
    }

    private static func layout(_ state: SidebarSessionTreeState?, parentPresent: Bool = true, crossMachine: Bool = false) -> SidebarLayout {
        var options = SidebarLayoutOptions()
        options.flattensMachines = true
        options.sessionTree = state
        return SidebarLayout.make(sections: sections(parentPresent: parentPresent, crossMachine: crossMachine), metrics: .standard, options: options)
    }

    @Test func liveChildAppearsOnceUnderParentAndCountsInHostBadge() throws {
        let layout = Self.layout(Self.state())
        let workspaces = layout.rows.compactMap { row -> WorkspaceID? in
            if case let .workspace(id) = row.key { id } else { nil }
        }
        #expect(workspaces == [Self.parent, Self.child, Self.other])
        #expect(layout.row(for: .workspace(Self.parent))?.content?.treeDepth == 1)
        #expect(layout.row(for: .workspace(Self.child))?.content?.treeDepth == 2)
        #expect(layout.row(for: .workspace(Self.parent))?.content?.treeFold == .expanded)
        #expect(layout.row(for: .sessionHost(Self.host))?.childCount == 2)
        let child = try #require(layout.row(for: .workspace(Self.child)))
        #expect(child.section == .machine(.local))
        #expect(child.siblingIndex == 2, "grouping must preserve document drop/selection identity")
    }

    @Test func closedOrOtherWindowParentLeavesChildAtMachineLevel() {
        let layout = Self.layout(Self.state(), parentPresent: false)
        #expect(layout.row(for: .workspace(Self.parent)) == nil)
        #expect(layout.row(for: .workspace(Self.child))?.content?.treeDepth == 1)
        #expect(layout.row(for: .sessionHost(Self.host))?.childCount == 1)
        #expect(layout.rows.filter { $0.key == .workspace(Self.child) }.count == 1)
    }

    @Test func crossMachineChildFollowsItsLiveParentInsteadOfGettingASecondGroup() {
        let layout = Self.layout(Self.state(crossHost: true), crossMachine: true)
        let keys = layout.rows.map(\.key)
        #expect(keys == [.sessionHost(Self.host), .workspace(Self.parent), .workspace(Self.child), .workspace(Self.other)])
        #expect(layout.row(for: .workspace(Self.child))?.section == .machine(MachineID("remote")))
        #expect(layout.row(for: .workspace(Self.child))?.content?.treeDepth == 2)
        #expect(layout.row(for: .sessionHost(Self.host))?.childCount == 2)
    }

    @Test func parentAndHostFoldsKeepTheWholeBadgeCount() {
        var state = Self.state()
        state.collapsed = [Self.parent]
        let parentFolded = Self.layout(state)
        #expect(parentFolded.row(for: .workspace(Self.child)) == nil)
        #expect(parentFolded.row(for: .workspace(Self.parent))?.content?.treeFold == .collapsed)
        #expect(parentFolded.row(for: .sessionHost(Self.host))?.childCount == 2)
        state.collapsedHosts = [Self.host]
        let hostFolded = Self.layout(state)
        #expect(hostFolded.rows.map(\.key) == [.sessionHost(Self.host), .workspace(Self.other)])
        #expect(hostFolded.row(for: .sessionHost(Self.host))?.childCount == 2)
    }

    @Test func disabledTreeAndWorkspacesWithoutAgentRefsKeepTheirExistingRows() {
        let disabled = Self.layout(nil)
        #expect(disabled.rows.map(\.key) == [.workspace(Self.parent), .workspace(Self.other), .workspace(Self.child)])
        let plain = SidebarSessionTreeFeed.pass([], lanes: [:], localHost: "install:local", pullRequests: [:]).state
        #expect(Self.layout(plain) == disabled)
    }

    @Test func explicitUserGroupKeepsItsStoredPlacement() {
        let group = SidebarGroup(id: GroupID("user-group"), name: "My project", workspaces: [SidebarWorkspace(id: Self.child, title: "Worker")])
        let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                     nodes: [.group(group)])
        var options = SidebarLayoutOptions()
        options.sessionTree = Self.state()
        let layout = SidebarLayout.make(sections: [section], metrics: .standard, options: options)
        #expect(layout.row(for: .workspace(Self.child))?.group == group.id)
        #expect(!layout.rows.contains { if case .sessionHost = $0.key { true } else { false } })
    }

    @Test func looseChildFollowsVisibleParentInsideAnExplicitUserGroup() {
        let group = SidebarGroup(id: GroupID("project"), name: "Project",
                                 workspaces: [SidebarWorkspace(id: Self.parent, title: "Coordinator")])
        let section = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                     nodes: [.group(group), .workspace(SidebarWorkspace(id: Self.child, title: "Worker"))])
        var options = SidebarLayoutOptions()
        options.sessionTree = Self.state()
        let layout = SidebarLayout.make(sections: [section], metrics: .standard, options: options)
        #expect(layout.rows.map(\.key) == [.group(group.id), .workspace(Self.parent), .workspace(Self.child)])
        #expect(layout.row(for: .workspace(Self.parent))?.group == group.id)
        #expect(layout.row(for: .workspace(Self.child))?.group == nil)
        #expect(layout.row(for: .workspace(Self.child))?.content?.treeDepth == 1)
        #expect(layout.row(for: .workspace(Self.child))?.depth == 1)
    }

    @Test func sessionTreeStillKeepsDoneAndLimitedRowsInsideTheCount() {
        var options = SidebarLayoutOptions()
        options.sessionTree = Self.state()
        options.foldsDone = true
        options.rowLimit = 1
        options.flattensMachines = true
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: options)
        #expect(layout.rows.map(\.key) == Self.layout(Self.state()).rows.map(\.key))
        #expect(layout.row(for: .sessionHost(Self.host))?.childCount == 2)
    }

    @Test func revealingChildOpensItsRootHostsFold() throws {
        let suite = "SidebarSessionHostTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tree = SidebarSessionTree(defaults: defaults)
        tree.state = Self.state(crossHost: true)
        tree.toggleHost(Self.host)
        tree.toggleHost("registry:other")
        tree.toggle(Self.parent)
        tree.reveal(Self.child)
        #expect(tree.drawn?.collapsedHosts.isEmpty == true)
        #expect(tree.drawn?.collapsed.isEmpty == true)
    }
}
