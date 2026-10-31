import CoreGraphics
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A group's fold splices its rows into the shown layout (`SidebarLayout.folding`) instead of laying the list out
/// again (plans/cmux-next/state-ownership-DESIGN.md). The splice must draw exactly what a full layout draws: every
/// fold, in every order, is checked against `SidebarLayout.make` of the same sections, row for row, with the key
/// lookups of the spliced layout answering for every row.
@MainActor @Suite struct SidebarLayoutFoldTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    /// Loose rows, then `groups` groups (one empty, one holding a link member), then loose rows again.
    static func sections(groups: Int = 6, perGroup: Int = 4) -> [SidebarSection] {
        var nodes: [SidebarNode] = (0..<3).map { .workspace(SidebarWorkspace(id: WorkspaceID("lead-\($0)"), title: "lead \($0)")) }
        for g in 0..<groups {
            let count = g == 2 ? 0 : perGroup
            var group = SidebarGroup(id: GroupID("g\(g)"), name: "Group \(g)", color: .green,
                                     workspaces: (0..<count).map { SidebarWorkspace(id: WorkspaceID("g\(g)-\($0)"), title: "g\(g) w\($0)") })
            if g == 3 {
                let link = SidebarListItem(id: "link-g3", ref: .url("https://example.com"), title: "Example")
                group.items = [SidebarGroupItem(item: link, after: group.workspaces.first?.id)]
            }
            nodes.append(.group(group))
        }
        nodes += (0..<3).map { .workspace(SidebarWorkspace(id: WorkspaceID("tail-\($0)"), title: "tail \($0)")) }
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static func setCollapsed(_ id: GroupID, _ collapsed: Bool, in sections: inout [SidebarSection]) {
        for s in sections.indices {
            for n in sections[s].nodes.indices {
                if case var .group(group) = sections[s].nodes[n], group.id == id {
                    group.isCollapsed = collapsed
                    sections[s].nodes[n] = .group(group)
                }
            }
        }
    }

    static func group(_ id: GroupID, in sections: [SidebarSection]) -> SidebarGroup? {
        for node in sections.flatMap(\.nodes) { if case let .group(group) = node, group.id == id { return group } }
        return nil
    }

    /// `sections()` with two tabs on every grouped workspace: what the list draws with `sidebar.showWorkspaceTabs`.
    static func sectionsWithTabs() -> [SidebarSection] {
        var sections = sections()
        for n in sections[0].nodes.indices {
            guard case var .group(group) = sections[0].nodes[n] else { continue }
            for w in group.workspaces.indices {
                let id = group.workspaces[w].id.rawValue
                group.workspaces[w].tabs = [SidebarTab(id: TabID("\(id)-t0"), title: "t0"), SidebarTab(id: TabID("\(id)-t1"), title: "t1")]
            }
            sections[0].nodes[n] = .group(group)
        }
        return sections
    }

    /// Folds `steps` one after another (each spliced into the last), comparing each with a full layout.
    func check(_ steps: [(GroupID, Bool)], active: WorkspaceID?, sections start: [SidebarSection] = SidebarLayoutFoldTests.sections(),
               options: SidebarLayoutOptions = SidebarLayoutOptions()) throws {
        var sections = start
        var o = options
        o.activeWorkspaceID = active
        let metrics = SidebarLayoutMetrics.standard
        var shown = SidebarLayout.make(sections: sections, metrics: metrics, options: o)
        for (id, collapsed) in steps {
            Self.setCollapsed(id, collapsed, in: &sections)
            let group = try #require(Self.group(id, in: sections))
            shown = try #require(shown.folding(group, collapsed: collapsed, in: sections[0], metrics: metrics, options: o),
                                 "the fold of \(id.rawValue) could not be spliced")
            let full = SidebarLayout.make(sections: sections, metrics: metrics, options: o)
            #expect(shown == full, "\(id.rawValue) collapsed=\(collapsed): the splice draws \(shown.rows.count) rows, a full layout \(full.rows.count)")
            for (position, row) in full.rows.enumerated() {
                #expect(shown.position(of: row.key) == position, "\(row.key) after folding \(id.rawValue)")
            }
        }
    }

    @Test func collapseThenExpandEachGroup() throws {
        var steps: [(GroupID, Bool)] = []
        for g in 0..<6 { steps.append((GroupID("g\(g)"), true)) }
        for g in (0..<6).reversed() { steps.append((GroupID("g\(g)"), false)) }
        try check(steps, active: nil)
    }

    @Test func collapsedGroupKeepsItsActiveMember() throws {
        try check([(GroupID("g1"), true), (GroupID("g1"), false), (GroupID("g1"), true)], active: WorkspaceID("g1-2"))
    }

    /// More folds than the key index keeps splices for (it is built again once): every lookup still answers.
    @Test func manyFoldsCompactTheIndex() throws {
        var steps: [(GroupID, Bool)] = []
        for i in 0..<(SidebarLayoutKeyIndex.compactAfter * 2 + 5) { steps.append((GroupID("g\(i % 6)"), i % 12 < 6)) }
        try check(steps, active: WorkspaceID("g4-0"))
    }

    /// Listed tabs (`sidebar.showWorkspaceTabs`, on by default since f32ee25f5a5) are spliced with their workspace,
    /// one with its tabs folded keeps its disclosure, and a folded group's kept member lists none: as a full layout.
    /// Before, any listed tabs sent every fold to a full list layout, so a toggle cost every row (SidebarGroupToggleScalingTests).
    @Test func listedTabsAreSplicedWithTheirWorkspace() throws {
        var o = SidebarLayoutOptions()
        o.showWorkspaceTabs = true
        o.collapsedWorkspaces = [WorkspaceID("g4-1")]
        var steps: [(GroupID, Bool)] = []
        for g in 0..<6 { steps.append((GroupID("g\(g)"), true)) }
        for g in (0..<6).reversed() { steps.append((GroupID("g\(g)"), false)) }
        try check(steps, active: WorkspaceID("g1-2"), sections: Self.sectionsWithTabs(), options: o)
    }

    /// The session tree orders a group's members under their parents and sets their depth (`treeOrder`); the splice
    /// lists them in group order at one depth, so with a tree the fold declines and the list is laid out again
    /// (`make`, which a full layout draws row for row).
    @Test func aSessionTreeLaysTheListOutAgain() throws {
        let sections = Self.sectionsWithTabs()
        var o = SidebarLayoutOptions()
        o.showWorkspaceTabs = true
        o.sessionTree = SidebarSessionTreeState(parents: [WorkspaceID("g1-0"): WorkspaceID("g1-3")])
        let shown = SidebarLayout.make(sections: sections, metrics: .standard, options: o)
        let group = try #require(Self.group(GroupID("g1"), in: sections))
        #expect(shown.folding(group, collapsed: true, in: sections[0], metrics: .standard, options: o) == nil)
    }

    /// The chat history's Pinned and Earlier blocks sit where the full layout leaves room; a splice would move the
    /// rows under Earlier (a click there resumed a chat) and leave a gap on close, so the list is laid out again.
    @Test func chatHistoryLaysTheListOutAgain() throws {
        let sections = Self.sections()
        var o = SidebarLayoutOptions()
        o.sessionTree = SidebarSessionTreeState()
        let chats = (0..<3).map { SidebarHistoryChat(id: "c\($0)", title: "chat \($0)", updatedAt: .distantPast) }
        o.chatHistory = SidebarChatHistoryState.make(newest: chats, chat: { id in chats.first { $0.id == id } }, live: [],
                                                     pinned: ["c0"], limit: 20, folded: false)
        let shown = SidebarLayout.make(sections: sections, metrics: .standard, options: o)
        #expect(shown.earlierChatsY != nil)
        let group = try #require(Self.group(GroupID("g1"), in: sections))
        #expect(shown.folding(group, collapsed: true, in: sections[0], metrics: .standard, options: o) == nil)
    }

    @Test func aFilterLaysTheListOutAgain() {
        let sections = Self.sections()
        var o = SidebarLayoutOptions()
        o.filterMatches = [WorkspaceID("g1-0")]
        let shown = SidebarLayout.make(sections: sections, metrics: .standard, options: o)
        let group = Self.group(GroupID("g1"), in: sections)
        #expect(group.flatMap { shown.folding($0, collapsed: true, in: sections[0], metrics: .standard, options: o) } == nil)
    }
}
