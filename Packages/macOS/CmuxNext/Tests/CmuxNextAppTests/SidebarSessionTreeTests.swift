import AppKit
@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-18, Claude desktop's Code tab: with `sidebar.sessionTree` on, a workspace whose
/// agent another workspace's agent started lists under it on a thin line, each row carries its
/// pull requests (green open, orange draft/conflict/red, purple merged), and the first rows show
/// their Command-number keycaps. Off, the list draws as before.
@MainActor @Suite(.serialized) struct SidebarSessionTreeTests {
    private static let chief = WorkspaceID("ws-chief")
    private static let other = WorkspaceID("ws-other")
    private static let lane = WorkspaceID("ws-lane")

    /// chief, other, lane in model order; lane's agent was started by chief's.
    private static let sections = [
        SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: chief, title: "chief")),
            .workspace(SidebarWorkspace(id: other, title: "other")),
            .workspace(SidebarWorkspace(id: lane, title: "lane")),
        ]),
    ]
    private static let tree = SidebarSessionTreeState(parents: [lane: chief],
                                                      pullRequests: [lane: SidebarPullRequestBadge(count: 2, status: .attention)])

    private static func drawn(_ options: SidebarLayoutOptions) -> [(WorkspaceID, Int)] {
        SidebarLayout.make(sections: sections, metrics: .standard, options: options).rows.compactMap { row in
            if case let .workspace(id) = row.key { (id, row.content?.treeDepth ?? 0) } else { nil }
        }
    }

    @Test func aStartedWorkspaceListsUnderItsParentOnlyWithTheTreeOn() {
        #expect(Self.drawn(SidebarLayoutOptions()).map { $0.0 } == [Self.chief, Self.other, Self.lane])
        var options = SidebarLayoutOptions()
        options.sessionTree = Self.tree
        let rows = Self.drawn(options)
        #expect(rows.map { $0.0 } == [Self.chief, Self.lane, Self.other])
        #expect(rows.map { $0.1 } == [0, 1, 0])
    }

    @Test func treeOrderLeavesCyclesAndOtherListsAlone() {
        let a = WorkspaceID("a"), b = WorkspaceID("b"), d = WorkspaceID("d"), far = WorkspaceID("far")
        // d's parent is in another list: d stays a root. (Depth: SidebarDeepTreeTests.)
        let order = SidebarLayout.treeOrder([nil, a, d], parents: [d: far])
        #expect(order.map { $0.index } == [0, 1, 2])
        #expect(order.map { $0.depth } == [0, 0, 0])
        // A cycle draws as it is.
        let cycle = SidebarLayout.treeOrder([a, b], parents: [a: b, b: a])
        #expect(cycle.map { $0.index } == [0, 1])
        #expect(cycle.map { $0.depth } == [0, 0])
        #expect(SidebarLayout.treeOrder([a, b], parents: nil).map { $0.index } == [0, 1])
    }

    @Test func aBadgeCountsItsPullRequestsInTheMostUrgentColor() {
        #expect(SidebarPullRequestBadge.combining([]) == nil)
        #expect(SidebarPullRequestBadge.combining([.merged, .passing]) == SidebarPullRequestBadge(count: 2, status: .passing))
        #expect(SidebarPullRequestBadge.combining([.passing, .attention, .merged])?.status == .attention)
        #expect(SidebarPullRequestBadge.combining([.attention, .failing, .passing])?.status == .failing)
        #expect(SidebarPullRequestBadge.combining([.merged])?.status == .merged)
    }

    @Test func aPullRequestsStatePicksItsColor() {
        func pr(_ state: String, mergeable: String = "mergeable", checks: String = "passing") -> AgentPanePullRequest {
            AgentPanePullRequest(url: "https://github.com/o/r/pull/1", number: 1, state: state, mergeable: mergeable,
                                 checks: .init(state: checks, passed: 1, total: 1))
        }
        #expect(SidebarSessionTreeFeed.status(pr("open")) == .passing)
        #expect(SidebarSessionTreeFeed.status(pr("open", checks: "pending")) == .passing)
        #expect(SidebarSessionTreeFeed.status(pr("open", checks: "failing")) == .failing)
        #expect(SidebarSessionTreeFeed.status(pr("open", mergeable: "conflicting")) == .attention)
        #expect(SidebarSessionTreeFeed.status(pr("draft")) == .attention)
        #expect(SidebarSessionTreeFeed.status(pr("merged")) == .merged)
        #expect(SidebarSessionTreeFeed.status(pr("closed")) == nil)
    }

    @Test func aLaneKeepsTheSessionThatStartedItAndItsFolder() throws {
        let lane = try #require(AgentActivityLane.of(summary: [
            "sessionId": "op", "name": "op", "spawnedBy": "chief", "cwd": "/src/app",
            "lane": ["state": "working"],
        ]))
        #expect(lane.spawnedBy == "chief")
        #expect(lane.cwd == "/src/app")
        let bare = try #require(AgentActivityLane.of(summary: ["sessionId": "x", "spawnedBy": "", "lane": ["state": "idle"]]))
        #expect(bare.spawnedBy == nil)
        #expect(bare.cwd == nil)
        #expect(bare.pullRequests.isEmpty)
    }

    @Test func aLaneKeepsThePullRequestsItsSessionOpened() throws {
        let lane = try #require(AgentActivityLane.of(summary: [
            "sessionId": "op", "lane": ["state": "idle"],
            "pullRequests": ["https://github.com/o/r/pull/1", "", 3, "https://github.com/o/s/pull/2"],
        ]))
        #expect(lane.pullRequests == ["https://github.com/o/r/pull/1", "https://github.com/o/s/pull/2"])
    }

    /// A session that opened pull requests from several branches counts each, once: its folder's
    /// branch's pull request may be one it opened, and two sessions may name the same one.
    @Test func aBadgeCountsEveryPullRequestItsSessionsOpenedOnce() {
        func lane(_ id: String, cwd: String?, opened: [String]) -> AgentActivityLane {
            AgentActivityLane(id: id, name: id, title: id, peer: nil, parent: nil, state: .idle, since: nil, error: nil,
                              cwd: cwd, pullRequests: opened)
        }
        func pr(_ number: Int, _ state: String) -> AgentPanePullRequest {
            AgentPanePullRequest(url: "https://github.com/o/r/pull/\(number)", number: number, state: state, mergeable: "mergeable",
                                 checks: .init(state: "passing", passed: 1, total: 1))
        }
        let lanes = [
            lane("a", cwd: "/src/app", opened: ["https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2"]),
            lane("b", cwd: "/src/app", opened: ["https://github.com/o/r/pull/2", "https://github.com/o/r/pull/3"]),
        ]
        let asks = SidebarSessionTreeFeed.asks(lanes)
        #expect(asks == ["/src/app", "https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2",
                         "https://github.com/o/r/pull/3"])
        // The folder's branch is pull/2; pull/3 has no answer yet.
        let answers = ["/src/app": pr(2, "open"), "https://github.com/o/r/pull/1": pr(1, "merged"),
                       "https://github.com/o/r/pull/2": pr(2, "open")]
        let badge = SidebarSessionTreeFeed.badge(asks, answers: answers)
        #expect(badge?.count == 2)
        #expect(badge?.status == .passing)
        #expect(badge?.items.map(\.number) == [2, 1])
        #expect(SidebarSessionTreeFeed.badge(asks, answers: [:]) == nil)
    }

    /// ask-268456b5a0 (Leo 2026-10-28, "loads of stuff in my sidebar that I'm not even looking at"): a session folded
    /// under its parent draws only as the parent's roll-up, so its steps and titles lay nothing out; its state does.
    @Test func aFoldedSessionsStepLaysNothingOutButItsStateDoes() {
        var tree = Self.tree
        tree.collapsed = [Self.chief]
        let working = SidebarWorkspace(id: Self.lane, title: "lane", agentWorking: true)
        var stepped = working
        stepped.agentStep = "Reading SidebarRowIndex.swift"
        stepped.title = "lane (renamed)"
        #expect(!tree.patchChangesRollUp(from: working, to: stepped))
        var done = stepped
        done.agentWorking = false
        #expect(tree.patchChangesRollUp(from: stepped, to: done))
        #expect(tree.patchChangesRollUp(from: nil, to: done))
        // Shown (no fold over it): its own row patches in place, as before.
        #expect(!Self.tree.patchChangesRollUp(from: stepped, to: done))
        // A lane's own state decides: the row's step under it changes nothing.
        tree.states[Self.lane] = .running
        #expect(!tree.patchChangesRollUp(from: working, to: done))
    }

    @Test func rowsDrawTheLineTheBadgeAndTheKeycaps() throws {
        SidebarSessionTree.shared.state = Self.tree
        defer { SidebarSessionTree.shared.state = nil }
        let sidebar = SidebarView(model: SidebarModel(sections: Self.sections), design: SidebarPullRequestBadgeTests.showingPullRequests())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow() // the design's row settings reach the model
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        let parent = try #require(sidebar.list.rowViews[.workspace(Self.chief)] as? WorkspaceRowView)
        let child = try #require(sidebar.list.rowViews[.workspace(Self.lane)] as? WorkspaceRowView)
        #expect(parent.treeLine.isHidden)
        #expect(!child.treeLine.isHidden)
        #expect(child.title.frame.minX > parent.title.frame.minX)
        #expect(!child.pullRequests.isHidden)
        #expect(child.pullRequests.badge == SidebarPullRequestBadge(count: 2, status: .attention))
        #expect(parent.pullRequests.isHidden)
        // The keycaps follow the drawn order: the child drawn right under its parent is the next digit.
        let first = try #require(parent.keycap.number)
        #expect(!parent.keycap.isHidden)
        #expect(child.keycap.number == first + 1)
        #expect(child.accessibilityLabel()?.contains(CmuxNextSidebar.Strings.pullRequests(SidebarPullRequestBadge(count: 2, status: .attention))) == true)
    }
}
