import AppKit
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-21 (sidebar organization, item A): every row carries its pull request badge, not only
/// with the session tree on. The tree's nesting, guide line and keycaps stay opt-in
/// (`sidebar.sessionTree`); the badge follows `sidebar.pullRequestBadges` (on by default).
@MainActor @Suite(.serialized) struct SidebarPullRequestBadgeTests {
    private static let chief = WorkspaceID("ws-chief")
    private static let other = WorkspaceID("ws-other")
    private static let lane = WorkspaceID("ws-lane")
    private static let badge = SidebarPullRequestBadge(count: 2, status: .attention)

    private static let sections = [
        SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: chief, title: "chief")),
            .workspace(SidebarWorkspace(id: other, title: "other")),
            .workspace(SidebarWorkspace(id: lane, title: "lane")),
        ]),
    ]

    @Test func withTheTreeOffTheFeedPublishesBadgesButNoTree() {
        let tree = SidebarSessionTree()
        let state = SidebarSessionTreeState(parents: [Self.lane: Self.chief], pullRequests: [Self.lane: Self.badge])
        SidebarSessionTreeFeed.publish(SidebarSessionTreeFeed.Pass(state: state, asks: [], nests: false), to: tree)
        #expect(tree.state == nil, "no nesting, guide lines or keycaps while the tree is off")
        #expect(tree.pullRequests == [Self.lane: Self.badge])

        SidebarSessionTreeFeed.publish(SidebarSessionTreeFeed.Pass(state: state, asks: [], nests: true), to: tree)
        #expect(tree.state == state)
        SidebarSessionTreeFeed.publish(nil, to: tree)
        #expect(tree.state == nil)
        #expect(tree.pullRequests.isEmpty)
    }

    @Test func aRowDrawsItsBadgeWithTheTreeOffInManualOrder() throws {
        SidebarSessionTree.shared.pullRequests = [Self.lane: Self.badge]
        defer { SidebarSessionTree.shared.pullRequests = [:] }
        let sidebar = SidebarView(model: SidebarModel(sections: Self.sections), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        let parent = try #require(sidebar.list.rowViews[.workspace(Self.chief)] as? WorkspaceRowView)
        let child = try #require(sidebar.list.rowViews[.workspace(Self.lane)] as? WorkspaceRowView)
        #expect(!child.pullRequests.isHidden)
        #expect(child.pullRequests.badge == Self.badge)
        #expect(parent.pullRequests.isHidden)
        #expect(child.treeLine.isHidden, "no nesting without the tree")
        #expect(child.keycap.isHidden && parent.keycap.isHidden, "no keycaps without the tree")
        #expect(child.frame.minY > parent.frame.minY || child.frame.maxY < parent.frame.maxY)
    }

    @Test func layoutOptionsCarryTheBadgeWithoutTheTree() {
        var options = SidebarLayoutOptions()
        options.pullRequests = [Self.lane: Self.badge]
        let rows = SidebarLayout.make(sections: Self.sections, metrics: .standard, options: options).rows
        let drawn = rows.compactMap { row -> (WorkspaceID, SidebarPullRequestBadge?, Int)? in
            if case let .workspace(id) = row.key { (id, row.content?.pullRequests, row.content?.treeDepth ?? 0) } else { nil }
        }
        #expect(drawn.map(\.0) == [Self.chief, Self.other, Self.lane], "manual order")
        #expect(drawn.map(\.1) == [nil, nil, Self.badge])
        #expect(drawn.map(\.2) == [0, 0, 0])
    }
}
