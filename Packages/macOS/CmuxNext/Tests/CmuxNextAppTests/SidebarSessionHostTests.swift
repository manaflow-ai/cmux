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

    private static func sections(parentPresent: Bool = true, crossMachine: Bool = false) -> [CmuxNextSidebar.SidebarSection] {
        let parentRow = SidebarWorkspace(id: parent, title: "Coordinator")
        let childRow = SidebarWorkspace(id: child, title: "Worker")
        let unrelated = SidebarWorkspace(id: other, title: "Shell")
        let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        if crossMachine {
            let remote = SidebarMachine(id: MachineID("remote"), name: "Remote", kind: .ssh)
            return [CmuxNextSidebar.SidebarSection(kind: .machine(local), nodes: parentPresent ? [.workspace(parentRow), .workspace(unrelated)] : [.workspace(unrelated)]),
                    CmuxNextSidebar.SidebarSection(kind: .machine(remote), nodes: [.workspace(childRow)])]
        }
        return [CmuxNextSidebar.SidebarSection(kind: .machine(local), nodes:
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
        #expect(layout.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local))))?.childCount == 2)
        let child = try #require(layout.row(for: .workspace(Self.child)))
        #expect(child.section == .machine(.local))
        #expect(child.siblingIndex == 2, "grouping must preserve document drop/selection identity")
    }

    @Test func closedOrOtherWindowParentLeavesChildAtMachineLevel() {
        let layout = Self.layout(Self.state(), parentPresent: false)
        #expect(layout.row(for: .workspace(Self.parent)) == nil)
        #expect(layout.row(for: .workspace(Self.child))?.content?.treeDepth == 1)
        #expect(layout.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local))))?.childCount == 1)
        #expect(layout.rows.filter { $0.key == .workspace(Self.child) }.count == 1)
    }

    @Test func crossMachineChildFollowsItsLiveParentInsteadOfGettingASecondGroup() {
        let layout = Self.layout(Self.state(crossHost: true), crossMachine: true)
        let keys = layout.rows.map(\.key)
        #expect(keys == [.sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local))), .workspace(Self.parent), .workspace(Self.child), .workspace(Self.other)])
        #expect(layout.row(for: .workspace(Self.child))?.section == .machine(MachineID("remote")))
        #expect(layout.row(for: .workspace(Self.child))?.content?.treeDepth == 2)
        #expect(layout.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local))))?.childCount == 2)
    }

    @Test func crossMachineChildStaysUnderItsOwnMachineHeaderWhenMachinesAreHeaded() throws {
        var options = SidebarLayoutOptions()
        options.flattensMachines = false
        options.sessionTree = Self.state(crossHost: true)
        let layout = SidebarLayout.make(sections: Self.sections(crossMachine: true), metrics: .standard, options: options)
        let keys = layout.rows.map(\.key)
        let remoteHeader = try #require(keys.firstIndex(of: .section(.machine(MachineID("remote")))))
        let child = try #require(keys.firstIndex(of: .workspace(Self.child)))
        #expect(child > remoteHeader, "a child must not draw under the previous machine's header")
        #expect(layout.row(for: .workspace(Self.child))?.section == .machine(MachineID("remote")))
        #expect(layout.row(for: .workspace(Self.parent))?.content?.treeFold == nil)
        for (index, row) in layout.rows.enumerated() where row.key != .section(row.section) {
            let header = keys[..<index].last { if case .section = $0 { true } else { false } }
            if let header { #expect(header == .section(row.section), "\(row.key) drew under \(header)") }
        }
    }

    @Test func parentAndHostFoldsKeepTheWholeBadgeCount() {
        var state = Self.state()
        state.collapsed = [Self.parent]
        let parentFolded = Self.layout(state)
        #expect(parentFolded.row(for: .workspace(Self.child)) == nil)
        #expect(parentFolded.row(for: .workspace(Self.parent))?.content?.treeFold == .collapsed)
        #expect(parentFolded.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local))))?.childCount == 2)
        state.collapsedHosts = [Self.host]
        let hostFolded = Self.layout(state)
        #expect(hostFolded.rows.map(\.key) == [.sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local))), .workspace(Self.other)])
        #expect(hostFolded.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local))))?.childCount == 2)
    }

    @Test func publishKeepsSessionTreeOffByDefault() {
        let tree = SidebarSessionTree(defaults: UserDefaults(suiteName: "SidebarSessionHostTests-off-\(UUID().uuidString)") ?? .standard)
        let pass = SidebarSessionTreeFeed.Pass(state: Self.state(), asks: [], showsTree: false)
        SidebarSessionTreeFeed.publish(pass, to: tree)
        #expect(tree.state == nil)
        #expect(tree.pullRequests.isEmpty)
    }

    @Test func localOnlyAgentRefsDoNotCreateAHostGroup() {
        let chats = [(Self.parent, [AgentSessionRef(host: "install:local", hostName: "This Mac", session: "local-agent")]),
                     (Self.child, [AgentSessionRef(host: "install:local", hostName: "This Mac", session: "local-worker")])]
        let pass = SidebarSessionTreeFeed.pass(chats, lanes: [:], localHost: "install:local", pullRequests: [:])
        #expect(pass.state.hosts.isEmpty)
        let alias = SidebarSessionTreeFeed.pass([(Self.parent, [AgentSessionRef(host: "registry:local", session: "alias")])], lanes: [:],
                                                hostAliases: ["install:local": ["registry:local"]], localHost: "install:local", pullRequests: [:])
        #expect(alias.state.hosts.isEmpty)
        #expect(Self.layout(pass.state) == Self.layout(nil))
    }

    @Test func pinnedParentDoesNotPullFleetChildAcrossSectionBoundary() {
        let pinned = CmuxNextSidebar.SidebarSection(kind: .pinned, nodes: [.workspace(SidebarWorkspace(id: Self.parent, title: "Pinned"))])
        let machine = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                     nodes: [.workspace(SidebarWorkspace(id: Self.child, title: "Worker"))])
        var options = SidebarLayoutOptions(); options.sessionTree = Self.state()
        let layout = SidebarLayout.make(sections: [pinned, machine], metrics: .standard, options: options)
        #expect(layout.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local)))) != nil)
        #expect(layout.row(for: .workspace(Self.child))?.content?.treeDepth == 1)
    }

    @Test func pinnedChildKeepsPinnedPlacementWhenItsParentIsAVisibleFleetLane() {
        let machine = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                     nodes: [.workspace(SidebarWorkspace(id: Self.parent, title: "Coordinator"))])
        let pinned = CmuxNextSidebar.SidebarSection(kind: .pinned, nodes: [.workspace(SidebarWorkspace(id: Self.child, title: "Pinned worker"))])
        var options = SidebarLayoutOptions(); options.sessionTree = Self.state()
        let layout = SidebarLayout.make(sections: [machine, pinned], metrics: .standard, options: options)
        #expect(layout.row(for: .workspace(Self.child))?.section == .pinned)
        #expect(layout.row(for: .workspace(Self.child))?.content?.treeDepth == 0)
    }

    @Test func missingLocalIdentityNeverTreatsLocalChatsAsFleet() {
        let chats = [(Self.parent, [AgentSessionRef(host: "install:unknown", hostName: "This Mac", session: "local")]),
                     (Self.child, [AgentSessionRef(host: "install:unknown", hostName: "This Mac", session: "worker")])]
        let recorded = [AgentSessionParents.identity(host: "install:unknown", session: "worker"):
                        AgentSessionParents.identity(host: "install:unknown", session: "local")]
        let pass = SidebarSessionTreeFeed.pass(chats, lanes: [:], recordedParents: recorded, localHost: nil, pullRequests: [:])
        #expect(pass.state.hosts.isEmpty)
        #expect(pass.state.parents[Self.child] == Self.parent)
    }

    @Test func lineageNestingRemainsInPinnedSectionWhenFleetHostsExist() {
        let pinned = CmuxNextSidebar.SidebarSection(kind: .pinned, nodes: [
            .workspace(SidebarWorkspace(id: Self.parent, title: "Pinned coordinator")),
            .workspace(SidebarWorkspace(id: Self.child, title: "Pinned worker")),
        ])
        let machine = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                     nodes: [.workspace(SidebarWorkspace(id: Self.other, title: "Remote root"))])
        var options = SidebarLayoutOptions(); options.sessionTree = Self.state()
        let layout = SidebarLayout.make(sections: [pinned, machine], metrics: .standard, options: options)
        #expect(layout.row(for: .workspace(Self.child))?.content?.treeDepth == 1)
        #expect(layout.row(for: .workspace(Self.child))?.section == .pinned)
    }

    @Test func hostGroupsStaySeparatedByMachineSection() {
        let first = SidebarMachine(id: MachineID("one"), name: "One", kind: .ssh)
        let second = SidebarMachine(id: MachineID("two"), name: "Two", kind: .ssh)
        let one = CmuxNextSidebar.SidebarSection(kind: .machine(first), nodes: [.workspace(SidebarWorkspace(id: Self.parent, title: "One root"))])
        let two = CmuxNextSidebar.SidebarSection(kind: .machine(second), nodes: [.workspace(SidebarWorkspace(id: Self.other, title: "Two root"))])
        var state = Self.state(); state.hosts[Self.other] = Self.host
        var options = SidebarLayoutOptions(); options.sessionTree = state
        let layout = SidebarLayout.make(sections: [one, two], metrics: .standard, options: options)
        #expect(layout.rows.filter { if case .sessionHost = $0.key { true } else { false } }.count == 2)
        #expect(layout.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(MachineID("one"))))) != nil)
        #expect(layout.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(MachineID("two"))))) != nil)
        #expect(layout.row(for: .workspace(Self.parent))?.section == .machine(MachineID("one")))
        #expect(layout.row(for: .workspace(Self.other))?.section == .machine(MachineID("two")))
    }

    @Test func disabledTreeAndWorkspacesWithoutAgentRefsKeepTheirExistingRows() {
        let disabled = Self.layout(nil)
        #expect(disabled.rows.map(\.key) == [.workspace(Self.parent), .workspace(Self.other), .workspace(Self.child)])
        let plain = SidebarSessionTreeFeed.pass([], lanes: [:], localHost: "install:local", pullRequests: [:]).state
        #expect(Self.layout(plain) == disabled)
    }

    @Test func explicitUserGroupKeepsItsStoredPlacement() {
        let group = SidebarGroup(id: GroupID("user-group"), name: "My project", workspaces: [SidebarWorkspace(id: Self.child, title: "Worker")])
        let section = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
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
        let section = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
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

    @Test func dragGapKeepsHostProjectionAndDropIdentity() throws {
        var options = SidebarLayoutOptions()
        options.sessionTree = Self.state()
        options.gap = DropPosition(section: .machine(.local), index: 1)
        options.gapHeight = 24
        options.showEmptyPinned = true
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: options)
        let gapY = try #require(layout.gapY)
        let target = try #require(layout.row(for: .workspace(Self.other)))
        #expect(target.y == gapY + layout.gapShift)
        #expect(layout.row(at: gapY + layout.gapHeight / 2) == nil)
        #expect(layout.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local)))) != nil)
        #expect(layout.rows.filter { $0.key == .workspace(Self.child) }.count == 1)
        #expect(layout.row(for: .workspace(Self.child))?.siblingIndex == 2)
    }

    @Test func dropBeforeReorderedChildAndAtListEndReservesRealSpace() throws {
        for index in [2, 3] {
            var options = SidebarLayoutOptions()
            options.sessionTree = Self.state()
            options.gap = DropPosition(section: .machine(.local), index: index)
            options.gapHeight = 24
            let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: options)
            let gapY = try #require(layout.gapY)
            if index == 2 {
                #expect(layout.row(for: .workspace(Self.child))?.y == gapY + layout.gapShift)
            } else {
                let last = try #require(layout.rows.last)
                #expect(gapY == last.maxY + layout.rowSpacing)
            }
            #expect(layout.row(at: gapY + layout.gapHeight / 2) == nil)
            #expect(layout.totalHeight >= gapY + layout.gapHeight)
        }
    }

    @Test func hostHeadersDisableInSidebarReordering() {
        #expect(Self.layout(Self.state()).hostHeadersShowing)
        #expect(!Self.layout(nil).hostHeadersShowing)
    }

    @Test func sectionEndDropDoesNotFollowAWorkspaceFromTheNextMachine() throws {
        var options = SidebarLayoutOptions()
        var state = Self.state()
        state.parents = [:]
        options.sessionTree = state
        options.flattensMachines = true
        options.gap = DropPosition(section: .machine(.local), index: 2)
        options.gapHeight = 24
        let layout = SidebarLayout.make(sections: Self.sections(crossMachine: true), metrics: .standard, options: options)
        let lastLocal = try #require(layout.row(for: .workspace(Self.other)))
        let gapY = try #require(layout.gapY)
        #expect(gapY == lastLocal.maxY + layout.rowSpacing)
        #expect(layout.row(at: gapY + layout.gapHeight / 2) == nil)
        #expect(layout.row(for: .workspace(Self.child))?.section == .machine(MachineID("remote")))
    }

    @Test func historyAndSectionGapsStayAtTheirBoundariesAfterReorderingAndFolding() throws {
        let chat = SidebarHistoryChat(id: "old", title: "Earlier chat", updatedAt: .distantPast)
        let history = SidebarChatHistoryState(pinned: [chat], earlier: [chat])
        let tail = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: "tail")), nodes: [])
        for hasTail in [false, true] {
            for folded in [false, true] {
                var options = SidebarLayoutOptions()
                var state = Self.state()
                if folded { state.collapsed = [Self.parent] }
                options.sessionTree = state
                options.chatHistory = history
                options.blockHeights = ["tail": 44]
                let sections = Self.sections() + (hasTail ? [tail] : [])
                let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: options)
                let metrics = SidebarLayoutMetrics.standard.resolved(for: options)
                let pinnedY = try #require(layout.pinnedChatsY)
                let earlierY = try #require(layout.earlierChatsY)
                let header = try #require(layout.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local)))))
                let lastWorkspace = try #require(layout.row(for: .workspace(Self.other)))
                #expect(header.y == pinnedY + history.pinnedHeight(metrics))
                #expect(earlierY == lastWorkspace.maxY + metrics.rowSpacing + metrics.sectionSpacing)
                if hasTail {
                    #expect(layout.row(for: .block("tail"))?.y == earlierY + history.earlierHeight(metrics))
                }
                #expect(layout.totalHeight >= earlierY + history.earlierHeight(metrics))
                // The moved child must not carry the section/history gap into its family.
                if !folded {
                    let parent = try #require(layout.row(for: .workspace(Self.parent)))
                    #expect(layout.row(for: .workspace(Self.child))?.y == parent.maxY + metrics.rowSpacing)
                }
            }
        }
    }

    @Test func pinnedHistoryAfterAnExplicitSectionStaysAboveTheHostHeader() throws {
        let pinned = CmuxNextSidebar.SidebarSection(kind: .pinned, nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("pin"), title: "Pinned"))])
        let history = SidebarChatHistoryState(pinned: [.init(id: "chat", title: "Chat", updatedAt: .distantPast)])
        var options = SidebarLayoutOptions()
        options.sessionTree = Self.state()
        options.chatHistory = history
        let layout = SidebarLayout.make(sections: [pinned] + Self.sections(), metrics: .standard, options: options)
        let metrics = SidebarLayoutMetrics.standard.resolved(for: options)
        let pinnedY = try #require(layout.pinnedChatsY)
        #expect(layout.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local))))?.y == pinnedY + history.pinnedHeight(metrics))
        let pin = try #require(layout.row(for: .workspace(WorkspaceID("pin"))))
        #expect(pinnedY == pin.maxY + metrics.rowSpacing + metrics.sectionSpacing)
    }

    @Test func sessionTreeStillKeepsDoneAndLimitedRowsInsideTheCount() {
        var options = SidebarLayoutOptions()
        options.sessionTree = Self.state()
        options.foldsDone = true
        options.rowLimit = 1
        options.flattensMachines = true
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: options)
        #expect(layout.rows.map(\.key) == Self.layout(Self.state()).rows.map(\.key))
        #expect(layout.row(for: .sessionHost(SidebarSessionTree.hostKey(Self.host, section: .machine(.local))))?.childCount == 2)
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
