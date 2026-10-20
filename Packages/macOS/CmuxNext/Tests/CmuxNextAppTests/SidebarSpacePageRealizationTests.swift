import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// "If I have a lot of workspaces open, changing spaces causes a bit of lag" (space-switch-fast):
/// the page a space switch slides out, and the page a swipe pulls in, is a list outside a scroll
/// view. It made a row view for every workspace of its space (its bounds were the whole document),
/// so each switch configured, laid out and drew hundreds of rows nobody saw. A page now makes views
/// for the rows in its frame only.
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

    @Test func theSlidOutPageMakesViewsForItsVisibleRowsOnly() throws {
        let (model, sidebar) = Self.sidebar()
        #expect(sidebar.list.rowViews.count <= Self.bound, "the live list realized \(sidebar.list.rowViews.count) rows")
        sidebar.spacePaging.prepareSlide(oldSections: model.sections)
        sidebar.spacePaging.slide(direction: 1)
        let page = try #require((sidebar.spacePaging.snapshotView as? SpacePageView)?.list)
        #expect(page.displayed.rows.count >= Self.rows)
        #expect(page.rowViews.count <= Self.bound, "the slid-out page made \(page.rowViews.count) row views for \(Self.rows) rows")
    }

    @Test func aSwipesNeighborPageMakesViewsForItsVisibleRowsOnly() throws {
        let (_, sidebar) = Self.sidebar()
        sidebar.spacePaging.scroll(.began, deltaX: -20, time: 0)
        let page = try #require(sidebar.spacePaging.neighbor?.list)
        #expect(page.displayed.rows.count >= Self.rows)
        #expect(page.rowViews.count <= Self.bound, "the swipe's page made \(page.rowViews.count) row views for \(Self.rows) rows")
        sidebar.spacePaging.scroll(.ended, deltaX: 0, time: 0.5)
    }

    /// A page shows the rows where the list was scrolled, not the space's first rows.
    @Test func theSlidOutPageKeepsTheListsScrollOffset() throws {
        let (model, sidebar) = Self.sidebar()
        let clip = sidebar.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 2_000))
        sidebar.scrollView.reflectScrolledClipView(clip)
        let offset = clip.bounds.minY
        try #require(offset > 0)
        sidebar.spacePaging.prepareSlide(oldSections: model.sections)
        sidebar.spacePaging.slide(direction: 1)
        let page = try #require((sidebar.spacePaging.snapshotView as? SpacePageView)?.list)
        let shown = page.rowViews.values.map { page.convert($0.frame, to: page.superview) }
        let pageBounds = try #require(page.superview?.bounds)
        #expect(shown.contains { $0.intersects(pageBounds) }, "no row view of the page is in its frame")
        let firstShown = page.displayed.rows.first { page.rowViews[$0.key] != nil }
        #expect((firstShown?.y ?? 0) >= offset - 400, "the page starts at row y \(firstShown?.y ?? 0), the list was at \(offset)")
    }
}
