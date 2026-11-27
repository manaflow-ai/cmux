import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// "If I have a lot of workspaces open, changing spaces causes a bit of lag" (space-switch-fast):
/// the page a swipe pulls in is a list outside a scroll view. It made a row view for every workspace
/// of its space (its bounds were the whole document), so each page configured, laid out and drew
/// hundreds of rows nobody saw. A page now makes views for the rows in its frame only. (A switch by
/// dot or key slid such a page out too, until 2026-11-10: it shows at rest now, with no page:
/// `SidebarSpaceSwitchAtRestTests`.)
@MainActor
struct SidebarSpacePageRealizationTests {
    static let rows = 300

    static func sections(_ prefix: String) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let workspaces = (0..<rows).map { SidebarWorkspace(id: WorkspaceID("\(prefix)-\($0)"), title: "\(prefix) \($0)") }
        return [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })]
    }

    static func sidebar() -> (SidebarModel, SidebarView) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections("a"), activeWorkspaceID: nil)
        model.profiles = (0..<2).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
        model.activeProfileID = ProfileKey("space0")
        model.spaceSections = { key in sections(key.rawValue) }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar)
    }

    /// At most the rows a 600 pt page shows, with the list's overscan above and below.
    static let bound = 80

    @Test func aSwipesNeighborPageMakesViewsForItsVisibleRowsOnly() throws {
        let (_, sidebar) = Self.sidebar()
        sidebar.spacePaging.scroll(.began, deltaX: -20, time: 0)
        let page = try #require(sidebar.spacePaging.neighbor?.list)
        #expect(page.displayed.rows.count >= Self.rows)
        #expect(page.rowViews.count <= Self.bound, "the swipe's page made \(page.rowViews.count) row views for \(Self.rows) rows")
        sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.5)
    }

    /// The next pull reuses the last page and its row views: a warm page makes no row view.
    @Test func theNextSwipeReusesThePageAndItsRowViews() throws {
        let (model, sidebar) = Self.sidebar()
        sidebar.spacePaging.scroll(.began, deltaX: -20, time: 0)
        let first = try #require(sidebar.spacePaging.neighbor?.list)
        let made = Set(first.rowViews.values.map(ObjectIdentifier.init))
        try #require(!made.isEmpty)
        // The fingers go back to where they started: the page leaves. They pull again, and the space beside lists other rows now.
        sidebar.spacePaging.scroll(.changed, deltaX: 20, time: 0.02)
        #expect(sidebar.spacePaging.neighbor == nil, "the page stayed with the fingers back at the start")
        model.spaceSections = { _ in Self.sections("b") }
        sidebar.spacePaging.scroll(.changed, deltaX: -20, time: 0.04)
        let second = try #require(sidebar.spacePaging.neighbor?.list)
        #expect(second === first)
        let reused = second.rowViews.values.map(ObjectIdentifier.init)
        #expect(reused.allSatisfy(made.contains), "\(reused.filter { !made.contains($0) }.count) of \(reused.count) row views were new")
        #expect(second.displayed.rows.contains { $0.key == .workspace(WorkspaceID("b-0")) })
        sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.5)
    }

    /// A swipe's settle whose sidebar goes away before it ends (a window closed mid-swipe) finishes without
    /// touching the sidebar: its completion reads the sidebar through a weak reference.
    @Test func aSwipeSettleOutlivingItsSidebarFinishesSafely() {
        var paging: SidebarSpacePaging?
        weak var gone: SidebarView?
        autoreleasepool {
            let (_, sidebar) = Self.sidebar()
            gone = sidebar
            paging = sidebar.spacePaging
            sidebar.spacePaging.scroll(.began, deltaX: -180, time: 0)
            sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.1)
            sidebar.removeFromSuperview()
        }
        #expect(gone == nil, "the sidebar outlived the test's scope, so the settle never ran without it")
        CATransaction.flush()
        for _ in 0..<4 { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3)) }
        #expect(paging != nil) // the process is still alive: the completion did not trap
    }

    /// An empty space's page draws nothing in its empty list, as the live list does (https://github.com/manaflow-ai/cmux/issues/32728).
    @Test func aSwipesEmptyPageDrawsNoEmptyStateText() throws {
        let (model, sidebar) = Self.sidebar()
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let empty = SidebarSection(kind: .machine(machine), nodes: [])
        model.spaceSections = { _ in [empty] }
        sidebar.spacePaging.scroll(.began, deltaX: -20, time: 0)
        let page = try #require(sidebar.spacePaging.neighbor?.list)
        page.layoutSubtreeIfNeeded()
        let row = try #require(page.rowViews[.emptySection(empty.id)] as? EmptySectionRowView)
        #expect(row.subviews.compactMap { $0 as? ChromeLabel }.filter { !$0.isHidden && !$0.stringValue.isEmpty }.isEmpty)
        sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.5)
    }
}
