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

    /// Folds `steps` one after another (each spliced into the last), comparing each with a full layout.
    func check(_ steps: [(GroupID, Bool)], active: WorkspaceID?) throws {
        var sections = Self.sections()
        var o = SidebarLayoutOptions()
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
