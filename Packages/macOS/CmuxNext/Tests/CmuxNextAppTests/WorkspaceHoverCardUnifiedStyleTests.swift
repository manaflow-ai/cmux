@testable import CmuxNextSidebar
@testable import CmuxNextDesign
import CmuxNextTestSupport
import AppKit
import Testing

/// Leo 2026-11-06, on the sidebar's workspace hover card: "it's got, like, a bit too much just default space,
/// maybe, and you got all these empty things" and "when you hover on the left, there's no glass". His card: an
/// agent chat row (title over its model), then a terminal "~" with no detail line, drawn two lines tall, so an
/// empty band sat above and below its one line; and the card under a veil of the window background.
@MainActor @Suite(.closesItsWindows)
struct WorkspaceHoverCardUnifiedStyleTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The tabs of Leo's screenshot: a Codex chat with its model, and a shell whose folder repeats its title.
    static var tabs: [SidebarTab] {
        var chat = SidebarTab(id: TabID("chat"), title: "neko-icons", kind: .agentChat, brand: "codex")
        chat.model = "gpt-6-astra"
        let shell = SidebarTab(id: TabID("shell"), title: "~", kind: .terminal, folder: "~")
        return [chat, shell]
    }

    @Test func aTabRowWithNoDetailLineIsOneRowTall() throws {
        let list = WorkspaceTabHoverCardView()
        list.configure(title: "neko", tabs: Self.tabs, now: Self.now)
        list.frame = NSRect(x: 0, y: 0, width: 264, height: list.intrinsicContentSize.height)
        list.layoutSubtreeIfNeeded()
        let chat = try #require(list.rowViews.first), shell = try #require(list.rowViews.dropFirst().first)
        #expect(chat.reportedLine.contains("gpt-6-astra"), "the chat row lost its model: \(chat.reportedLine)")
        #expect(shell.reportedLine == "~", "the shell row has a detail line: \(shell.reportedLine)")
        let card = SidebarRowTokens.current.hoverCard
        #expect(abs(chat.frame.height - card.tabRowHeightTwoLines) < 0.5, "the chat row is \(chat.frame.height) pt")
        #expect(abs(shell.frame.height - card.tabRowHeight) < 0.5,
                "the shell row with no detail is \(shell.frame.height) pt, not one row (\(card.tabRowHeight) pt)")
        // One gap between rows, and the list ends at its last row: no empty band under "~".
        #expect(abs(shell.frame.minY - chat.frame.maxY - Metrics.space1) < 0.5)
        #expect(abs(list.intrinsicContentSize.height - shell.frame.maxY) < 0.5)
    }

    @Test func theWorkspaceCardStandsOnTheSharedGlass() {
        #expect(WorkspaceTabHoverCardStyle.standard.material == .glass)
        let card = WorkspaceHoverCardView()
        card.configure(WorkspaceHoverCardContent(title: "Optional Neko icon theme for cmux", icon: .agentChat, facts: []), now: Self.now)
        card.configureTabs(title: "neko", tabs: Self.tabs, now: Self.now)
        card.applyColors()
        #expect(card.layer?.backgroundColor == nil, "the card paints a veil over the hover card glass")
        // Concentric around its tab rows, which round like a sidebar row (Lawrence 2026-11-09, `WorkspaceHoverCardEvenInsetTests`).
        #expect(card.layer?.cornerRadius == WorkspaceHoverCardView.cardCornerRadius)
    }

    /// Every hover card's title-to-row and row-to-row gaps are the shared style's (`HoverCardStyle`): `space2`,
    /// as the tab strip's card and a link's card space their rows.
    @Test func theGroupCardUsesTheSharedSpacing() throws {
        let card = GroupHoverCardView()
        card.configure(GroupHoverCardSummary(title: "Agents", blocks: [
            .init(section: .status, lines: ["All idle"], tone: .secondary),
            .init(section: .members, lines: ["Workspaces: 1", "\u{2022} api"], tone: .secondary),
        ]))
        let stack = try #require(card.subviews.compactMap { $0 as? NSStackView }.first)
        let title = try #require(stack.arrangedSubviews.first)
        #expect(stack.spacing == Metrics.space2)
        #expect(stack.customSpacing(after: title) == Metrics.space2)
    }
}
