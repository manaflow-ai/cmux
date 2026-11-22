import CmuxNextBridge
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextIcons
@testable import CmuxNextSidebar
import Foundation
import Testing

/// David Beyer, 2026-11-20: rolling summaries of every chat with a next action for each. acpmux
/// keeps one on each chat's row (`rollingSummary`, `hub/rolling_summary.rs`); the sidebar's hover
/// card names it with its next action, and an expanded row's line reads it before the raw last reply.
@MainActor @Suite struct SidebarRollingSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theRowCarriesTheRollingSummaryAndNextAction() throws {
        let summary: [String: Any] = [
            "sessionId": "chat-1",
            "rollingSummary": ["text": " Parser fixed, CI running. ", "next": "Merge the PR", "source": "model", "turn": 3, "at": 1],
        ]
        let detail = try #require(AgentChatDetail.of(summary: summary))
        #expect(detail.summary == "Parser fixed, CI running.")
        #expect(detail.nextAction == "Merge the PR")
        // No next action, a blank summary, or an older acpmux with none: nothing.
        let alone = try #require(AgentChatDetail.of(summary: ["rollingSummary": ["text": "Done."]]))
        #expect(alone.summary == "Done." && alone.nextAction == nil)
        #expect(AgentChatDetail.of(summary: ["rollingSummary": ["text": "  "]]) == nil)
        #expect(AgentChatDetail.of(summary: ["sessionId": "chat-2"]) == nil)
    }

    private func workspace(summary: String?, next: String?, lastMessage: String? = "I finished the adapter.") -> SidebarWorkspace {
        var workspace = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("ws-summary"), machineID: CmuxNextSidebar.MachineID("local"),
                                         title: "Parser fix")
        workspace.agentName = "Claude"
        workspace.lastMessage = lastMessage
        workspace.detail.summary = summary
        workspace.detail.nextAction = next
        return workspace
    }

    @Test func theHoverCardNamesTheSummaryAndNextActionInsteadOfTheLastReply() throws {
        let card = WorkspaceHoverCardContent.make(workspace(summary: "Parser fixed, CI running.", next: "Merge the PR"),
                                                  machine: nil, now: now)
        let kinds = card.facts.map(\.kind)
        let summary = try #require(card.facts.first { $0.kind == "summary" })
        let next = try #require(card.facts.first { $0.kind == "nextAction" })
        #expect(summary.text == "Parser fixed, CI running.")
        #expect(summary.isMessage)
        #expect(next.text == "Next: Merge the PR")
        #expect(next.icon == .actionGo)
        #expect(kinds.firstIndex(of: "nextAction") == kinds.firstIndex(of: "summary").map { $0 + 1 })
        // The summary says more than the raw last reply, which then does not show.
        #expect(!kinds.contains("lastReply"))
        // Before the first summary the card is as it was: the last reply is its last line.
        let before = WorkspaceHoverCardContent.make(workspace(summary: nil, next: nil), machine: nil, now: now)
        #expect(before.facts.map(\.kind).last == "lastReply")
        #expect(!before.facts.contains { $0.kind == "summary" || $0.kind == "nextAction" })
    }

    @Test func theTaskListsNextStepWinsOverTheSummarysNextAction() throws {
        var ws = workspace(summary: "Parser fixed, CI running.", next: "Merge the PR")
        ws.taskProgress = SidebarTaskProgress(done: 1, total: 3, current: "Run the fleet tests", next: "Write the docs")
        let kinds = WorkspaceHoverCardContent.make(ws, machine: nil, now: now).facts.map(\.kind)
        #expect(kinds.contains("summary") && kinds.contains("taskNext"))
        #expect(!kinds.contains("nextAction"), "two Next lines: \(kinds)")
    }

    @Test func theHistoryFirstLayoutsKeepTheSummaryAndNextAction() {
        for layout in [WorkspaceHoverCardOptions.Layout.minimal, .log, .timeline] {
            var options = WorkspaceHoverCardOptions()
            options.layout = layout
            let card = WorkspaceHoverCardContent.make(workspace(summary: "Parser fixed.", next: "Merge the PR"), machine: nil, now: now,
                                                      options: options, timeline: [])
            #expect(card.facts.map(\.kind).filter { $0 == "summary" || $0 == "nextAction" } == ["summary", "nextAction"], "\(layout)")
        }
    }

    @Test func anExpandedRowReadsTheSummaryWithItsNextActionBeforeTheLastReply() {
        let row = WorkspaceRowContent(expanded: workspace(summary: "Parser fixed, CI running.", next: "Merge the PR"), now: now)
        #expect(row.detail == "Parser fixed, CI running. → Merge the PR")
        let alone = WorkspaceRowContent(expanded: workspace(summary: "Menu planned.", next: nil), now: now)
        #expect(alone.detail == "Menu planned.")
        let before = WorkspaceRowContent(expanded: workspace(summary: nil, next: "ignored"), now: now)
        #expect(before.detail == "I finished the adapter.")
        // An unread notification still comes first.
        var notified = workspace(summary: "Menu planned.", next: nil)
        notified.notificationText = "Needs your approval"
        #expect(WorkspaceRowContent(expanded: notified, now: now).detail == "Needs your approval")
    }
}
