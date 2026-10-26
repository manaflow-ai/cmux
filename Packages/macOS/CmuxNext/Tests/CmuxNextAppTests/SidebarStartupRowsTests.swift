import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// p08-startup-064: a launch builds the sidebar rows on screen only; the overscan rows past the
/// screen wait until after startup. Measured with 60 workspaces in a 600 pt sidebar.
@MainActor @Suite(.serialized) struct SidebarStartupRowsTests {
    static let workspaces = 60

    static func make(holding: Bool) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let rows = (0..<workspaces).map { SidebarWorkspace(id: WorkspaceID("su-\($0)"), title: "Workspace \($0)") }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })],
                                 activeWorkspaceID: rows.first?.id)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        if holding { sidebar.holdOffscreenRowsForLaunch() }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    /// The number that decided the change: without the hold, the overscan builds more than 2 rows
    /// past the screen.
    @Test func withoutTheHoldTheOverscanBuildsMoreThanTwoRowsPastTheScreen() throws {
        let (sidebar, window) = Self.make(holding: false)
        defer { window.close() }
        let onScreen = sidebar.list.rowsOnScreen
        try #require(onScreen > 4, "rows on screen: \(onScreen)")
        let past = sidebar.list.rowViews.count - onScreen
        print("sidebar-startup-rows: \(Self.workspaces) workspaces, \(onScreen) on screen, \(past) past the screen")
        #expect(past > 2, "\(past) rows past the screen: the overscan is small enough to keep at launch")
    }

    /// The acceptance: rows built before startup completes <= the rows on screen + 2.
    @Test func aLaunchBuildsOnlyTheRowsOnScreen() throws {
        let (unheld, unheldWindow) = Self.make(holding: false)
        defer { unheldWindow.close() }
        let (sidebar, window) = Self.make(holding: true)
        defer { window.close() }
        let list = sidebar.list
        let onScreen = list.rowsOnScreen
        try #require(onScreen > 4, "rows on screen: \(onScreen)")
        #expect(list.rowPool.made <= onScreen + 2, "\(list.rowPool.made) row views made for \(onScreen) rows on screen")
        #expect(list.rowViews.count < unheld.list.rowViews.count, "the hold built as many rows as the overscan")
    }

    @Test func afterStartupTheRowsPastTheScreenGetTheirViews() throws {
        let (sidebar, window) = Self.make(holding: true)
        defer { window.close() }
        let list = sidebar.list
        let made = list.rowPool.made, onScreen = list.rowsOnScreen
        sidebar.releaseOffscreenRows()
        #expect(!list.startupRows.isHeld)
        #expect(list.startupRows.builtBeforeRelease == made)
        #expect(list.startupRows.visibleAtRelease == onScreen)
        let realize = list.realizationRect()
        #expect(realize.height > list.enclosingScrollView?.contentView.bounds.height ?? 0, "the overscan is back")
        let missing = list.displayed.rows.filter { list.frame(for: $0).intersects(realize) && list.rowViews[$0.key] == nil }
        #expect(missing.isEmpty, "\(missing.count) overscan rows have no view after startup")
        // A second release (another window's, a late call) changes nothing.
        let after = list.rowPool.made
        sidebar.releaseOffscreenRows()
        #expect(list.rowPool.made == after)
        #expect(list.startupRows.builtBeforeRelease == made)
    }

    /// Under the hold a scroll still shows its rows: the rows that come on screen get views.
    @Test func aScrollDuringTheHoldShowsEveryRowOnScreen() throws {
        let (sidebar, window) = Self.make(holding: true)
        defer { window.close() }
        let clip = sidebar.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 800))
        sidebar.scrollView.reflectScrolledClipView(clip)
        sidebar.list.realizeVisibleRows()
        let visible = clip.bounds
        try #require(visible.minY > 0)
        let list = sidebar.list
        let missing = list.displayed.rows.filter { list.frame(for: $0).intersects(visible) && list.rowViews[$0.key] == nil }
        #expect(missing.isEmpty, "\(missing.count) rows on screen have no view")
        #expect(list.startupRows.isHeld)
    }
}
