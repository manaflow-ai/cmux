@testable import CmuxNextBridge
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo, 2026-11-25, on the subagent lines under a chat row: "idk who asked for those in the sidebar". A chat's
/// subagents draw no line under its row, in any tree state: the row keeps the height of a row without them, gets
/// no chevron for them, and only its failed subagents show, counted on the title line's one failed mark.
@MainActor @Suite struct SidebarSubagentRowsTests {
    private static let chat = WorkspaceID("ws-chat")
    private static let tab = TabID("tab-chat")

    private static func subagents(_ states: [SidebarSubagent.State], total: Int? = nil) -> SidebarSubagents {
        SidebarSubagents(items: states.enumerated().map { index, state in
            SidebarSubagent(id: "t\(index)", title: "Task \(index)", state: state, tab: tab)
        }, total: total, chat: tab)
    }

    private static func layout(_ subagents: SidebarSubagents?, tree: SidebarSessionTreeState?) -> SidebarRow? {
        var ws = SidebarWorkspace(id: chat, title: "Fix product grid layout shift")
        ws.subagents = subagents
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                       nodes: [.workspace(ws), .workspace(SidebarWorkspace(id: WorkspaceID("next"), title: "next"))])]
        var options = SidebarLayoutOptions()
        options.sessionTree = tree
        return SidebarLayout.make(sections: sections, metrics: .standard, options: options).row(for: .workspace(chat))
    }

    @Test func aChatsSubagentsNeverDrawLinesUnderItsRow() throws {
        for tree: SidebarSessionTreeState? in [nil, SidebarSessionTreeState(), SidebarSessionTreeState(collapsed: [Self.chat])] {
            let bare = try #require(Self.layout(nil, tree: tree))
            for states: [SidebarSubagent.State] in [[.running], [.done, .running, .failed], Array(repeating: .done, count: 8)] {
                let row = try #require(Self.layout(Self.subagents(states, total: 4_277), tree: tree))
                #expect(row.height == bare.height, "\(states) grows the row (tree \(tree != nil))")
                #expect(row.content?.treeFold == nil, "\(states) gives the row a chevron of its own")
            }
        }
    }

    @Test func failedSubagentsAreTheTitleLinesFailedMark() throws {
        for tree: SidebarSessionTreeState? in [nil, SidebarSessionTreeState()] {
            let failed = try #require(Self.layout(Self.subagents([.done, .running, .failed, .failed]), tree: tree)?.content)
            #expect(failed.subagentsFailed == 2)
            #expect(failed.drawnRollUp == SidebarTreeRollUp(failed: 2))
            let quiet = try #require(Self.layout(Self.subagents([.done, .running]), tree: tree)?.content)
            #expect(quiet.subagentsFailed == 0)
            #expect(quiet.drawnRollUp == nil)
        }
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
