@testable import CmuxNextBridge
@testable import CmuxNextSidebar
import CoreGraphics
import Foundation
import Testing

/// Leo, 2026-11-19 ("for claude there's the font and the nested sessions and whatever"): a chat's subagents
/// list under its row as the Claude desktop app's Code tab nests a chat's tasks. With the session tree on,
/// an open row draws one line per subagent (at most five, then "N more") and a folded one a single
/// stacked line; with it off, no subagent line at all (https://github.com/manaflow-ai/cmux/issues/52977).
@MainActor @Suite struct SidebarSubagentRowsTests {
    private static let chat = WorkspaceID("ws-chat")
    private static let tab = TabID("tab-chat")

    private static func subagents(_ states: [SidebarSubagent.State], total: Int? = nil) -> SidebarSubagents {
        SidebarSubagents(items: states.enumerated().map { index, state in
            SidebarSubagent(id: "t\(index)", title: "Task \(index)", state: state, tab: tab)
        }, total: total, chat: tab)
    }

    private static func layout(_ subagents: SidebarSubagents?, tree: SidebarSessionTreeState?,
                               look: SidebarSubagentLook = .both) -> SidebarRow? {
        var ws = SidebarWorkspace(id: chat, title: "Fix product grid layout shift")
        ws.subagents = subagents
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                       nodes: [.workspace(ws), .workspace(SidebarWorkspace(id: WorkspaceID("next"), title: "next"))])]
        var options = SidebarLayoutOptions()
        options.sessionTree = tree
        options.subagentLook = look
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options).row(for: .workspace(chat))
    }

    @Test func anOpenChatListsItsSubagentsAsRowsUnderItsName() throws {
        let row = try #require(Self.layout(Self.subagents([.done, .running, .failed]), tree: SidebarSessionTreeState()))
        let strip = try #require(row.content?.subagents)
        #expect(strip.mode == .rows)
        #expect(strip.rows.map(\.subagent.id) == ["t0", "t1", "t2"])
        #expect(strip.more == 0)
        #expect(row.content?.treeFold == .expanded, "the chat gets the tree's chevron to fold them")
        let bare = try #require(Self.layout(nil, tree: SidebarSessionTreeState()))
        #expect(row.height == bare.height + 3 * SidebarLayoutMetrics.standard.subagentLineHeight)
    }

    /// Leo 2026-11-23: the tree read "4,162 more" under a chat with 19 running. "N more" counts the subagents
    /// that run now and no row shows, never the ones the chat started in all.
    @Test func manyFinishedSubagentsCostFiveRowsAndNoMoreLine() throws {
        let row = try #require(Self.layout(Self.subagents(Array(repeating: .done, count: 8), total: 4162), tree: SidebarSessionTreeState()))
        let strip = try #require(row.content?.subagents)
        #expect(strip.rows.count == SidebarSubagentStrip.visibleRows)
        #expect(strip.rows.first?.subagent.id == "t3", "the latest ones")
        #expect(strip.more == 0, "finished ones are never counted as more")
        #expect(strip.lineCount == 5)
        #expect(Strings.moreSubagents(35) == "35 more")
    }

    @Test func runningOnesFillTheRowsFirstAndMoreCountsOnlyTheRunningLeftOver() throws {
        // Eight listed: t0..t6 running, t7 done; acpmux says 19 run, 4162 were started.
        let items = Self.subagents([.running, .running, .running, .running, .running, .running, .running, .done], total: 4162)
        let strip = try #require(SidebarSubagentStrip.make(SidebarSubagents(items: items.items, total: 4162, running: 19, chat: Self.tab),
                                                           tree: true, folded: false))
        #expect(strip.rows.map(\.subagent.id) == ["t2", "t3", "t4", "t5", "t6"], "the five latest that run, the done one left out")
        #expect(strip.more == 14, "19 run, 5 shown")
    }

    @Test func aChildRowListsItsOwnSubagentsAndTheParentDoesNotRepeatThem() throws {
        let parent = WorkspaceID("parent"), child = WorkspaceID("child")
        func chat(_ prefix: String, running: Int, total: Int) -> SidebarSubagents {
            SidebarSubagents(items: (0..<running).map { SidebarSubagent(id: "\(prefix)\($0)", title: prefix, state: .running, tab: Self.tab) },
                             total: total, running: running, chat: Self.tab)
        }
        var parentWS = SidebarWorkspace(id: parent, title: "claude-sr2-coord")
        // The parent's chats include the child's session, so its list holds the child's lines too.
        parentWS.subagents = SidebarSubagents(items: chat("own", running: 2, total: 40).items + chat("kid", running: 3, total: 269).items,
                                              total: 309, running: 5, chat: Self.tab)
        var childWS = SidebarWorkspace(id: child, title: "Background suite stop")
        childWS.subagents = chat("kid", running: 3, total: 269)
        let below = SidebarLayout.subagentsBelow([child: parent], workspaces: [parentWS, childWS])
        #expect(below[parent] == ["kid0", "kid1", "kid2"])
        #expect(below[child] == nil)
        var options = SidebarLayoutOptions()
        options.sessionTree = SidebarSessionTreeState(parents: [child: parent])
        options.subagentsBelow = below
        let own = try #require(options.rowContent(parentWS, machine: nil).subagents)
        #expect(own.rows.map(\.subagent.id) == ["own0", "own1"])
        #expect(own.more == 0)
        let kid = try #require(options.rowContent(childWS, machine: nil).subagents)
        #expect(kid.rows.map(\.subagent.id) == ["kid0", "kid1", "kid2"])
    }

    @Test func aFoldedChatShowsOneStackedLine() throws {
        let tree = SidebarSessionTreeState(collapsed: [Self.chat])
        let strip = try #require(Self.layout(Self.subagents([.done, .running, .running]), tree: tree)?.content?.subagents)
        #expect(strip.mode == .stack)
        #expect(strip.lineCount == 1)
        #expect(strip.marks.first == .running)
        #expect(Strings.subagentStack(strip) == "2 running")
        let finished = try #require(Self.layout(Self.subagents([.done, .done, .failed], total: 9), tree: tree)?.content?.subagents)
        #expect(Strings.subagentStack(finished) == "8 done · 1 failed")
        let stopped = try #require(Self.layout(Self.subagents([.done, .stopped, .stopped]), tree: tree)?.content?.subagents)
        #expect(stopped.done == 1, "a stopped subagent is not done")
    }

    /// https://github.com/manaflow-ai/cmux/issues/52977: a "✧ 1 running" line under a row, with the tree off,
    /// read as a stray line above the next row. Off the tree a row draws no subagent line in any look, and
    /// keeps the height of a row without subagents; its working indicator says the agent runs.
    @Test func withTheTreeOffARowDrawsNoSubagentLine() throws {
        let bare = try #require(Self.layout(nil, tree: nil))
        for look in SidebarSubagentLook.allCases {
            for states: [SidebarSubagent.State] in [[.running], [.done, .running], [.done, .failed]] {
                let row = try #require(Self.layout(Self.subagents(states), tree: nil, look: look))
                #expect(row.content?.subagents == nil, "\(look) \(states) draws a subagent line off the tree")
                #expect(row.height == bare.height, "\(look) \(states) grows the row off the tree")
                #expect(row.content?.treeFold == nil, "no chevron off the tree")
            }
        }
        #expect(SidebarSubagentStrip.make(Self.subagents([.running]), tree: false, folded: false) == nil)
    }

    @Test func theThreeLooks() throws {
        let tree = SidebarSessionTreeState()
        #expect(Self.layout(Self.subagents([.running]), tree: tree, look: .rows)?.content?.subagents?.mode == .rows)
        #expect(Self.layout(Self.subagents([.running]), tree: tree, look: .stack)?.content?.subagents?.mode == .stack)
        #expect(Self.layout(Self.subagents([.running]), tree: tree, look: .both)?.content?.subagents?.mode == .rows)
    }

    @Test func aSubagentUnderAListedOneSitsOneLevelDeeper() throws {
        var subagents = Self.subagents([.running, .running])
        subagents.items[1].parent = "t0"
        let strip = try #require(SidebarSubagentStrip.make(subagents, tree: true, folded: false))
        #expect(strip.rows.map(\.depth) == [1, 2])
    }

    @Test func aFoldOnAChatWithOnlySubagentsSurvivesTheSave() {
        let defaults = UserDefaults(suiteName: "SidebarSubagentRowsTests-\(UUID().uuidString)")!
        let tree = SidebarSessionTree(defaults: defaults)
        tree.state = SidebarSessionTreeState(parents: [WorkspaceID("lane"): WorkspaceID("chief")])
        tree.toggle(Self.chat, keeping: [Self.chat])
        #expect(tree.collapsed.contains(Self.chat))
        tree.toggle(WorkspaceID("chief"), keeping: [Self.chat])
        #expect(tree.collapsed == [Self.chat, WorkspaceID("chief")])
    }

    @Test func theSummaryListReachesTheChatDetail() throws {
        let summary: [String: Any] = [
            "sessionId": "s1", "subagentsSeen": 12,
            "recentSubagents": [
                ["id": "a1", "title": "Review the diff", "state": "done"],
                ["id": "a2", "parent": "a1", "state": "running"],
                ["id": "", "state": "done"], ["id": "a3"],
            ],
        ]
        let detail = try #require(AgentChatDetail.of(summary: summary))
        #expect(detail.subagents == [AgentChatDetail.Subagent(id: "a1", title: "Review the diff", state: "done"),
                                     AgentChatDetail.Subagent(id: "a2", parent: "a1", state: "running")])
        #expect(detail.subagentsSeen == 12)
        // An older acpmux lists none.
        let old = try #require(AgentChatDetail.of(summary: ["sessionId": "s1", "model": "m"]))
        #expect(old.subagents.isEmpty && old.subagentsSeen == 0)
    }
}
