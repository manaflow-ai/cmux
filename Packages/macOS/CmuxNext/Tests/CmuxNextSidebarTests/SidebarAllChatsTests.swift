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
        let center = NSPoint(x: view.searchButton.frame.midX, y: view.searchButton.frame.midY)
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

    /// At the narrowest sidebar the header still fits: the whole title, then
    /// icon buttons (search, filter, group), nothing overlapping or cut off. 160 pt is the
    /// default `sidebarMinWidth`.
    @Test(arguments: [CGFloat(160), 200, 260])
    func theHeaderFitsAtEveryWidth(width: CGFloat) {
        let view = chats([Self.row("codex:a", harness: "codex", folder: "/p/alpha"), Self.row("codex:b", harness: "codex", folder: "/p/beta")])
        view.frame.size.width = width
        view.layoutSubtreeIfNeeded()
        view.layout()
        #expect(!view.filterButton.isHidden, "two projects: the filter shows too")
        #expect(view.titleLabel.frame.width >= ceil(view.titleLabel.intrinsicContentSize.width), "the title is not cut off at \(width)")
        let controls = [view.searchButton, view.filterButton, view.groupButton].map(\.frame)
        for frame in controls {
            #expect(frame.minX >= view.titleLabel.frame.maxX && frame.maxX <= width, "\(frame) at \(width)")
        }
        for (a, b) in zip(controls, controls.dropFirst()) { #expect(!a.intersects(b)) }
    }

    /// Search opens a field in the title's place; an empty field closes again.
    @Test func searchOpensInTheTitlesPlace() {
        let view = chats()
        #expect(view.search.isHidden && !view.titleLabel.isHidden)
        view.openSearch()
        view.layout()
        #expect(!view.search.isHidden && view.titleLabel.isHidden && view.searchButton.isHidden)
        #expect(view.isHeaderRevealed, "an open search keeps the header shown")
        #expect(view.search.frame.width > 60)
    }

    /// Group by is a menu with the four groupings; picking one regroups.
    @Test func groupByIsAMenu() {
        let view = chats()
        let menu = view.groupingMenu()
        #expect(menu.items.count == SidebarChatsGrouping.allCases.count)
        #expect(menu.items.first?.state == .on, "Newest is checked")
        menu.performActionForItem(at: 1)
        #expect(view.selectedGrouping == .harness)
        #expect(view.numberOfRows(in: NSTableView()) > Self.rows.count, "harness headers appear")
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

    /// Default minimal mode (`.bottom`) hides the footer row at rest, but not
    /// the All chats rows: only their header waits for the hover.
    @Test func minimalModeKeepsAllChatsRowsShownAtRest() {
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.minimalMode = .bottom
        defer { DesignSettings.shared.sidebarSections = saved }
        let model = SidebarModel()
        model.layout = SidebarLayoutDocument.defaults.chatsLayout(enabled: true)
        let sidebar = SidebarView(model: model)
        let provider = Provider()
        sidebar.appSections = provider
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 800)
        sidebar.setChromeRevealed(false)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.layout()
        #expect(sidebar.minimalHiddenBands.bottom, "the footer row hides at rest")
        #expect(sidebar.belowFade.alphaValue == 1, "the All chats rows stay shown")
        #expect(!provider.view.isHeaderRevealed, "the header waits for the hover")
        // Without All chats the band below hides with the footer, as before.
        let plain = SidebarView(model: SidebarModel())
        plain.frame = NSRect(x: 0, y: 0, width: 260, height: 800)
        plain.setChromeRevealed(false)
        plain.layoutSubtreeIfNeeded()
        plain.layout()
        #expect(plain.belowRegion.restAlpha(hiddenByMode: true) == 0)
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
