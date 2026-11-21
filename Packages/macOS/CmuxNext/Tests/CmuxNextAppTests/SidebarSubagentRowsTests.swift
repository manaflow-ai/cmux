@testable import CmuxNextBridge
@testable import CmuxNextSidebar
import CoreGraphics
import Foundation
import Testing

/// Leo, 2026-11-19 ("for claude there's the font and the nested sessions and whatever"): a chat's subagents
/// list under its row as the Claude desktop app's Code tab nests a chat's tasks. With the session tree on,
/// an open row draws one line per subagent (at most five, then "N more") and a folded one a single
/// stacked line; with it off, the stacked line shows only while one runs and folds away after.
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

    @Test func manySubagentsCostFiveRowsAndAMoreLine() throws {
        let row = try #require(Self.layout(Self.subagents(Array(repeating: .done, count: 8), total: 40), tree: SidebarSessionTreeState()))
        let strip = try #require(row.content?.subagents)
        #expect(strip.rows.count == SidebarSubagentStrip.visibleRows)
        #expect(strip.rows.first?.subagent.id == "t3", "the latest ones")
        #expect(strip.more == 35)
        #expect(strip.lineCount == 6)
        #expect(Strings.moreSubagents(35) == "35 more")
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
    }

    @Test func withTheTreeOffOnlyRunningWorkShowsAndItFoldsAway() throws {
        let running = try #require(Self.layout(Self.subagents([.done, .running]), tree: nil)?.content?.subagents)
        #expect(running.mode == .stack)
        #expect(Self.layout(Self.subagents([.done, .failed]), tree: nil)?.content?.subagents == nil)
        #expect(Self.layout(Self.subagents([.done, .running]), tree: nil)?.content?.treeFold == nil, "no chevron off the tree")
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
