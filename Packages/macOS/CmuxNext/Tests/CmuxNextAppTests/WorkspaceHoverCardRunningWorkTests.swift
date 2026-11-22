import AppKit
@testable import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-01, on the sidebar hover preview of a lead agent that ran about ten background
/// subagents: "e.g. this hover preview being able to see the # of associated subagents and
/// whatnot would be a lot more useful / like the details aren't even very useful". The card counts
/// each agent's running subagents and commands (acpmux's summary), names them in its details, and
/// its History lists what was asked, not acpmux's "[inbox] New messages…" notices.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardRunningWorkTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theSummaryCountsReachTheChatDetail() throws {
        let summary: [String: Any] = [
            "sessionId": "s1", "model": "claude-opus-5-5",
            "turn": ["startedAt": 1_000, "prompt": "[inbox] New messages from other agents in 1 thread.", "notice": true],
            "subagentsRunning": 3, "subagentNames": ["Review", "Fix", "Gallery"], "commandsRunning": 1,
        ]
        let detail = try #require(AgentChatDetail.of(summary: summary))
        #expect(detail.subagentsRunning == 3)
        #expect(detail.subagentNames == ["Review", "Fix", "Gallery"])
        #expect(detail.commandsRunning == 1)
        #expect(detail.promptIsNotice)
        // An older acpmux says none of it.
        let old = try #require(AgentChatDetail.of(summary: ["sessionId": "s1", "model": "m"]))
        #expect(old.subagentsRunning == 0 && old.commandsRunning == 0 && !old.promptIsNotice)
    }

    @Test func anInboxNoticeTurnIsNoPromptInTheHistory() {
        let notice = AgentChatDetail(turnStartedAtMs: 5_000, prompt: "[inbox] New messages from other agents in 1 thread.",
                                     promptIsNotice: true)
        let events = AgentTimeline.chatEvents(from: nil, nil, to: .working, notice, nowMs: 9_000)
        #expect(events == [AgentTimelineEvent(kind: .started, atMs: 5_000, isNotice: true)])
        let person = AgentChatDetail(turnStartedAtMs: 6_000, prompt: "Fix the build")
        #expect(AgentTimeline.chatEvents(from: nil, nil, to: .working, person, nowMs: 9_000).map(\.kind) == [.prompt])

        let history = [
            SidebarTimelineEntry(kind: .finished, date: Self.now, agent: "Claude Code"),
            SidebarTimelineEntry(kind: .started, date: Self.now.addingTimeInterval(-60), agent: "Claude Code", isNotice: true),
            SidebarTimelineEntry(kind: .prompt, date: Self.now.addingTimeInterval(-600), text: "Fix the build", agent: "Claude Code"),
        ]
        let workspace = SidebarWorkspace(id: WorkspaceID("ws"), title: "UI lead")
        let card = WorkspaceHoverCardContent.make(workspace, machine: nil, now: Self.now, options: WorkspaceHoverCardOptions(),
                                                  timeline: history)
        #expect(!card.timeline.contains { $0.isNotice }, "the History lists no inbox notice")
        #expect(card.timeline.map(\.text) == [nil, "Fix the build"])
        // The stats count the person's one prompt, and the notice turn's work.
        #expect(card.stats?.contains("1") == true, "stats: \(card.stats ?? "nil")")
        #expect(card.stats?.contains("10m") == true, "stats: \(card.stats ?? "nil")")
    }

    @Test func anAgentWithRunningSubagentsShowsTheirCountAndNames() {
        var workspace = SidebarWorkspace(id: WorkspaceID("ws"), title: "UI lead")
        workspace.detail.subagentsRunning = 3
        workspace.detail.commandsRunning = 1
        workspace.detail.subagentNames = ["Review the hover card", "Fix the sidebar test", "Gallery captures"]
        let card = WorkspaceHoverCardContent.make(workspace, machine: nil, now: Self.now, options: WorkspaceHoverCardOptions(), timeline: [])
        let running = card.facts.filter { $0.kind == WorkspaceHoverCardWork.countKind || $0.kind == WorkspaceHoverCardWork.subagentKind }
        #expect(running.map(\.text) == ["3 subagents · 1 command", "Review the hover card", "Fix the sidebar test", "Gallery captures"])

        // The other two styles the gallery shows.
        #expect(WorkspaceHoverCardWork.facts(workspace.detail, style: .summary).map(\.text) == ["3 subagents · 1 command"])
        #expect(WorkspaceHoverCardWork.facts(workspace.detail, style: .inline).map(\.text)
            == ["3 subagents · 1 command: Review the hover card, Fix the sidebar test, Gallery captures"])

        // Nothing running: no line at all.
        let idle = WorkspaceHoverCardContent.make(SidebarWorkspace(id: WorkspaceID("idle"), title: "idle"), machine: nil, now: Self.now,
                                                  options: WorkspaceHoverCardOptions(), timeline: [])
        #expect(!idle.facts.contains { $0.kind == WorkspaceHoverCardWork.countKind })
        #expect(WorkspaceHoverCardWork.counts(subagents: 1, commands: 0) == "1 subagent")
    }

    @Test func eachTabRowCountsItsAgentsRunningSubagents() {
        var lead = SidebarTab(id: TabID("lead"), title: "dev-lane/ui-lead", kind: .agentChat, state: .working)
        lead.subagentsRunning = 10
        let quiet = SidebarTab(id: TabID("other"), title: "Other chat", kind: .agentChat, folder: "~/src", state: .idle)
        let list = WorkspaceTabHoverCardView()
        list.configure(title: "UI lead", tabs: [lead, quiet])
        #expect(list.reportedLines.first?.contains("10 subagents") == true, "\(list.reportedLines)")
        #expect(list.reportedLines.last?.contains("subagent") == false, "\(list.reportedLines)")
        #expect(WorkspaceHoverCardWork.tabCaption(lead) == "10 subagents")
        #expect(WorkspaceHoverCardWork.tabCaption(quiet) == "~/src")
    }
}
