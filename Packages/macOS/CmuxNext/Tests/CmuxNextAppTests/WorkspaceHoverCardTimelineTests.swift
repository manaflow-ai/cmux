import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// u3320 (Lawrence 2026-10-19): "I want to see the history of prompts that were sent, as well as
/// when they were sent and when Codex completed. I want to know when Claude started waiting for my
/// input ... We also need to make it more customizable." The workspace card lists a history,
/// newest first, scrolls it, and its layout and parts follow `sidebar.hoverCards.*`.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardTimelineTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func history(_ count: Int = 6) -> [SidebarTimelineEntry] {
        // Newest first: alternating finished turns and prompts, a minute apart.
        (0..<count).map { index in
            let date = now.addingTimeInterval(-Double(index) * 60)
            return index.isMultiple(of: 2)
                ? SidebarTimelineEntry(kind: .finished, date: date, agent: "Codex")
                : SidebarTimelineEntry(kind: .prompt, date: date, text: "Prompt \(index)", agent: "Codex")
        }
    }

    static func workspace() -> SidebarWorkspace {
        var workspace = SidebarWorkspace(id: WorkspaceID("ws-1"), title: "site", directory: "~/Projects/site", branch: "main")
        workspace.ports = ":3000"
        workspace.pullRequest = "#42"
        return workspace
    }

    static func options(_ layout: WorkspaceHoverCardOptions.Layout, _ change: (inout WorkspaceHoverCardOptions) -> Void = { _ in }) -> WorkspaceHoverCardOptions {
        var options = WorkspaceHoverCardOptions()
        options.layout = layout
        change(&options)
        return options
    }

    @Test func theDefaultCardListsTheHistoryNewestFirstWithStats() {
        let card = WorkspaceHoverCardContent.make(Self.workspace(), machine: nil, now: Self.now, options: WorkspaceHoverCardOptions(), timeline: Self.history())
        #expect(card.options.layout == .timeline)
        #expect(card.timeline.map(\.kind) == [.finished, .prompt, .finished, .prompt, .finished, .prompt])
        #expect(card.timeline.first?.date == Self.now)
        // Three prompts, each a minute before its finish.
        #expect(card.stats?.contains("3") == true)
        #expect(card.stats?.contains("3m") == true, "stats: \(card.stats ?? "nil")")
        #expect(card.facts.contains { $0.kind == "ports" && $0.text == ":3000" })
        #expect(card.facts.contains { $0.kind == "branch" })
    }

    @Test func sectionsTurnPartsOff() {
        let options = Self.options(.timeline) {
            $0.showsGit = false
            $0.showsPorts = false
            $0.showsWaiting = false
            $0.showsTimings = false
        }
        let card = WorkspaceHoverCardContent.make(Self.workspace(), machine: nil, now: Self.now, options: options, timeline: Self.history())
        #expect(!card.facts.contains { $0.kind == "branch" || $0.kind == "pullRequest" || $0.kind == "ports" })
        #expect(card.timeline.allSatisfy { $0.kind == .prompt })
        #expect(card.stats == nil)
        #expect(card.activitySince == nil)
    }

    @Test func maxRowsCapsTheHistory() {
        let card = WorkspaceHoverCardContent.make(Self.workspace(), machine: nil, now: Self.now,
                                                  options: Self.options(.timeline) { $0.maxRows = 4 }, timeline: Self.history(10))
        #expect(card.timeline.count == 4)
    }

    @Test(arguments: WorkspaceHoverCardOptions.Layout.allCases)
    func eachLayoutShowsItsParts(_ layout: WorkspaceHoverCardOptions.Layout) {
        let card = WorkspaceHoverCardContent.make(Self.workspace(), machine: nil, now: Self.now, options: Self.options(layout), timeline: Self.history())
        switch layout {
        case .timeline: #expect(card.timeline.count == 6 && !card.facts.isEmpty && card.stats != nil)
        case .compact: #expect(card.timeline.count == 3 && !card.facts.isEmpty && card.stats == nil)
        case .log: #expect(card.timeline.count == 6 && card.facts.isEmpty)
        case .classic: #expect(card.timeline.isEmpty && card.stats == nil && !card.facts.isEmpty)
        case .minimal: #expect(card.timeline.isEmpty && card.facts.map(\.text) == ["Prompt 1"])
        }
    }

    @Test func theNewestWaitSaysWhyWhileTheWorkspaceWaits() {
        var workspace = Self.workspace()
        workspace.activity = .waiting(kind: nil)
        workspace.detail.needsInput = "Allow Bash: rm -rf build?"
        let timeline = [SidebarTimelineEntry(kind: .waiting, date: Self.now, agent: "Claude Code")] + Self.history()
        let card = WorkspaceHoverCardContent.make(workspace, machine: nil, now: Self.now, options: WorkspaceHoverCardOptions(), timeline: timeline)
        #expect(card.timeline.first?.text == "Allow Bash: rm -rf build?")
    }

    @Test func theCardViewListsTheHistoryAndCapsItsHeight() throws {
        let view = WorkspaceHoverCardView()
        let card = WorkspaceHoverCardContent.make(Self.workspace(), machine: nil, now: Self.now, options: WorkspaceHoverCardOptions(), timeline: Self.history(40))
        view.configure(card, now: Self.now)
        view.detailsToggle.performClick(nil)
        view.layoutSubtreeIfNeeded()
        let lines = view.lines
        #expect(lines.contains { $0.hasSuffix("Prompt 1") }, "lines: \(lines)")
        #expect(lines.contains { $0.contains("Codex finished") }, "lines: \(lines)")
        #expect(view.timeline.scrollView.frame.height <= WorkspaceHoverCardView.timelineMaxHeight + 0.5)
        #expect(view.fittingSize.height < 600, "the card grew with its history: \(view.fittingSize.height)")
    }

    // MARK: Recording

    @Test func aCodexChatNotesItsPromptItsWaitAndItsFinish() {
        let turns = AgentTurnStateStore()
        turns.localHost = "install:test"
        let detail = AgentChatDetail(turnStartedAtMs: 1_000, prompt: "Add a test", laneState: "working", laneSinceMs: 1_000)
        turns.apply(session: "s1", state: .working, lastMessage: nil, muted: false, title: nil, detail: detail)
        turns.apply(session: "s1", state: .needsInput, lastMessage: nil, muted: false, title: nil,
                    detail: AgentChatDetail(turnStartedAtMs: 1_000, prompt: "Add a test", laneState: "input", laneSinceMs: 2_000))
        turns.apply(session: "s1", state: nil, lastMessage: "Done", muted: false, title: nil,
                    detail: AgentChatDetail(laneState: "idle", laneSinceMs: 3_000))
        // The watch closing is no moment of the chat.
        turns.apply(session: "s1", state: .working, lastMessage: nil, muted: false, title: nil,
                    detail: AgentChatDetail(turnStartedAtMs: 4_000, prompt: "Again", laneSinceMs: 4_000))
        turns.clearLive()
        let ref = AgentSessionRef(host: "install:test", session: "s1", harness: "codex")
        let events = turns.timeline(for: ref).events
        #expect(events.map(\.kind) == [.prompt, .waiting, .finished, .prompt])
        #expect(events.map(\.atMs) == [1_000, 2_000, 3_000, 4_000])
        #expect(events.first?.text == "Add a test")
    }
}
