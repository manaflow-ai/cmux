import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// cx-xub5 (Lawrence 2026-10-09): the All chats section at the bottom of the
/// sidebar lists every chat newest first; its header (title, search, project
/// filter, grouping) shows only while the pointer is over the sidebar; its
/// row count follows `sidebar.allChatsRows`.
@MainActor @Suite(.serialized) struct SidebarAllChatsTests {
    private static func row(_ id: String, harness: String, folder: String? = nil) -> SidebarChatsView.Row {
        SidebarChatsView.Row(id: id, title: id, harness: harness, brand: nil, folder: folder)
    }

    /// Newest first, as the feed orders them, across harnesses.
    private static let rows = [row("codex:a", harness: "codex"), row("claude-code:b", harness: "claude-code"),
                               row("opencode:c", harness: "opencode"), row("codex:d", harness: "codex")]

    private func chats(_ rows: [SidebarChatsView.Row] = Self.rows) -> SidebarChatsView {
        let view = SidebarChatsView(frame: NSRect(x: 0, y: 0, width: 260, height: 400),
                                    defaults: UserDefaults(suiteName: "all-chats-\(UUID())")!)
        view.update(rows, enabled: true, ready: true)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// One flat list in feed order: no harness group headers between the chats.
    @Test func chatsListNewestFirstWithNoGroupHeaders() {
        let view = chats()
        #expect(view.selectedGrouping == .newest)
        #expect(view.shownChatIDs == Self.rows.map(\.id))
        #expect(view.numberOfRows(in: NSTableView()) == Self.rows.count, "only chat rows, no headers")
    }

    /// The header is faded out and takes no clicks until the sidebar is hovered.
    @Test func theHeaderShowsOnlyOnHover() {
        let view = chats()
        let center = NSPoint(x: view.search.frame.midX, y: view.search.frame.midY)
        #expect(!view.isHeaderRevealed)
        #expect(view.header.alphaValue == 0)
        #expect(view.header.hitTest(center) == nil, "a hidden search field takes no click")
        view.setHoverRevealed(true)
        #expect(view.isHeaderRevealed)
        #expect(view.header.hitTest(center) != nil)
        view.setHoverRevealed(false)
        #expect(!view.isHeaderRevealed)
        #expect(view.header.hitTest(center) == nil)
    }

    /// A search or project filter in effect keeps the header shown, so missing
    /// rows always have a visible reason.
    @Test func anActiveSearchOrFilterKeepsTheHeaderShown() {
        let view = chats([Self.row("codex:a", harness: "codex", folder: "/p/alpha"), Self.row("codex:b", harness: "codex", folder: "/p/beta")])
        view.search.stringValue = "a"
        view.refilter()
        #expect(view.isHeaderRevealed)
        view.search.stringValue = ""
        view.refilter()
        #expect(!view.isHeaderRevealed)
        view.projectMenu().performActionForItem(at: 1)
        #expect(view.isHeaderRevealed)
        #expect(view.header.alphaValue == 1)
    }

    /// The section is the header row plus at most `sidebar.allChatsRows` rows (then it scrolls).
    @Test func theRowCountFollowsTheSetting() {
        let many = (0..<40).map { Self.row("codex:\($0)", harness: "codex") }
        let view = chats(many)
        #expect(view.preferredHeight == Metrics.sidebarRowHeight * CGFloat(1 + SidebarSectionsPreferences.defaultAllChatsRows))
        view.rowLimit = 3
        #expect(view.preferredHeight == Metrics.sidebarRowHeight * 4)
        let few = chats([Self.row("codex:a", harness: "codex")])
        few.rowLimit = 3
        #expect(few.preferredHeight == Metrics.sidebarRowHeight * 2, "a short list takes only its rows")
    }

    /// The App's provider gives the section no title, so the band draws no
    /// title row of its own; hovering the sidebar reveals the section's header.
    final class Provider: SidebarAppSectionProvider {
        let view = SidebarChatsView(defaults: UserDefaults(suiteName: "SidebarAllChatsTests") ?? .standard)
        var onContentChange: (() -> Void)?
        init() { view.update(SidebarAllChatsTests.rows, enabled: true, ready: true) }
        func title(for contribution: String) -> String? { nil }
        func makeView(for contribution: String) -> NSView? { contribution == SidebarChatsView.contribution ? view : nil }
        func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
            contribution == SidebarChatsView.contribution ? view.preferredHeight : 0
        }
    }

    @Test func hoveringTheSidebarRevealsTheHeaderAndTheBandAddsNoTitleRow() throws {
        let model = SidebarModel()
        model.layout = SidebarLayoutDocument.defaults.chatsLayout(enabled: true)
        let sidebar = SidebarView(model: model)
        let provider = Provider()
        sidebar.appSections = provider
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 800)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.layout()
        #expect(provider.view.superview === sidebar.belowRegion, "All chats draws in the band below the workspaces")
        #expect(sidebar.belowRegion.headerViews[SidebarLayoutDocument.recentsSectionID] == nil, "no band title row")
        #expect(!provider.view.isHeaderRevealed)
        sidebar.setChromeRevealed(true)
        #expect(provider.view.isHeaderRevealed)
        sidebar.setChromeRevealed(false)
        #expect(!provider.view.isHeaderRevealed)
    }
}
