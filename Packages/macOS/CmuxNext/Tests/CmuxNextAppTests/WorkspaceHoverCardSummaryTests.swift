import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-20: the session hover card was a scrolling "History" of truncated prompts and
/// "claude-sr2 finished" lines, mushy, with an awkward inner scroll. "Make it more useful, no
/// scroll, crisp" (ChatGPT's session card is the floor). The default card is the compact one: the
/// title with its machine icon, age and unread dot; folder, branch, machine and pull request; the
/// status with how long it has held; the agent's last message rendered, not raw markdown; then
/// the last three moments, one line each. It never scrolls.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardSummaryTests {
    static let now = WorkspaceHoverCardTimelineTests.now

    static func workspace() -> SidebarWorkspace {
        var workspace = WorkspaceHoverCardTimelineTests.workspace()
        workspace.title = "GUI push · coordinator (this chat)"
        workspace.unread = .dot
        workspace.lastActivity = now.addingTimeInterval(-2 * 3600)
        workspace.activity = .working
        workspace.detail.activitySince = now.addingTimeInterval(-4 * 60)
        workspace.lastMessage = "**Merged** #22670. Next: `fix` the [hover card](https://example.com/pr).\n\n- one\n- two"
        return workspace
    }

    @Test func theDefaultCardIsTheCompactOne() {
        #expect(WorkspaceHoverCardOptions().layout == .compact)
    }

    @Test func theCompactCardSaysWhatMatters() throws {
        let card = WorkspaceHoverCardContent.make(Self.workspace(), machine: nil, now: Self.now, options: WorkspaceHoverCardOptions(),
                                                  timeline: WorkspaceHoverCardTimelineTests.history(10))
        #expect(card.unread, "the unread workspace shows no unread dot")
        #expect(card.age == "2h")
        let kinds = card.facts.map(\.kind)
        for kind in ["folder", "branch", "pullRequest"] { #expect(kinds.contains(kind), "no \(kind) in \(kinds)") }
        let reply = try #require(card.facts.first { $0.kind == WorkspaceHoverCardContent.Fact.lastReplyKind })
        #expect(reply.text == "Merged #22670. Next: fix the hover card. one two", "the last message reads raw: \(reply.text)")
        #expect(reply.lines == 3)
        #expect(card.timeline.count == 3)
        #expect(card.stats == nil)
    }

    @Test func theCompactCardNeverScrolls() throws {
        let view = WorkspaceHoverCardView()
        let card = WorkspaceHoverCardContent.make(Self.workspace(), machine: nil, now: Self.now, options: WorkspaceHoverCardOptions(),
                                                  timeline: WorkspaceHoverCardTimelineTests.history(40))
        view.configure(card, now: Self.now)
        view.layoutSubtreeIfNeeded()
        #expect(!view.timeline.scrollView.hasVerticalScroller, "the history scrolls")
        let document = try #require(view.timeline.scrollView.documentView)
        #expect(document.frame.height <= view.timeline.scrollView.frame.height + 0.5, "the history is taller than its view")
        #expect(view.fittingSize.height < 360, "the card is \(view.fittingSize.height) pt tall")
        #expect(!view.lines.contains { $0.contains("**") || $0.contains("`") }, "lines: \(view.lines)")
    }
}
