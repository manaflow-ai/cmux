import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// REOPEN-F7: a reopened window whose active workspace is far down its list built the sidebar's rows twice before the
/// first frame. The first apply realized the rows at offset 0, then the reveal scrolled the clip to the active
/// workspace and the clip's bounds observer realized the rows around it (profile 10, 100 workspaces: 57 row views for
/// about 22 on screen; NSScrollView.scrollContent 16 ms of SidebarView.render's 45). Chrome draws its first frame
/// before it builds content that is not on screen: the first rows go straight to the revealed offset, and only the
/// rows in view (plus the overscan) get a view.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFirstRowsBuildOnceTests {
    private static let count = 100, active = 80, height: CGFloat = 640

    private static func host(active: Int = active, height: CGFloat = height) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ids = (0..<count).map { WorkspaceID("first-rows-\($0)") }
        let nodes = ids.enumerated().map { index, id in
            SidebarNode.workspace(SidebarWorkspace(id: id, title: "project-\(index)", directory: "~/p\(index)"))
        }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: ids[active])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        return (sidebar, window)
    }

    /// The rows a list of this height can show at once, plus the overscan above and below.
    private static func budget(_ list: SidebarListView) -> Int {
        let visible = list.enclosingScrollView?.contentView.bounds.height ?? height
        let rowHeight = Metrics.sidebarRowHeight
        return Int(((visible + 2 * SidebarStyle.overscan) / rowHeight).rounded(.up)) + 2
    }

    /// A window's first frame as WindowController makes it: the sidebar is made (its list reloads with no size), the
    /// window's frame lays it out, the first render runs, then the window shows and displays. Returns the row views made.
    private static func firstFrame(active: Int, height: CGFloat = height) -> (SidebarView, NSWindow, Int) {
        _ = SidebarPerfCounters.report(reset: true)
        let (sidebar, window) = host(active: active, height: height)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        window.displayIfNeeded()
        return (sidebar, window, SidebarPerfCounters.report(reset: true)["row_views_made"] ?? 0)
    }

    private static func placement(_ sidebar: SidebarView) -> String {
        let clip = sidebar.list.enclosingScrollView?.contentView.bounds ?? .zero
        return "clip y \(clip.minY) h \(clip.height), \(sidebar.list.rowViews.count) row views now"
    }

    @Test func theFirstRowsWithTheActiveRowFarDownAreBuiltOnce() throws {
        let (sidebar, window, made) = Self.firstFrame(active: Self.active)
        defer { window.close() }
        let budget = Self.budget(sidebar.list)
        #expect(made <= budget, "the first frame built \(made) row views; the rows in view plus the overscan are \(budget) (\(Self.placement(sidebar)))")
        // The active workspace is on screen in that first frame.
        let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("first-rows-\(Self.active)"))],
                               "the active row has no view after the first frame (\(Self.placement(sidebar)))")
        let clip = try #require(sidebar.list.enclosingScrollView?.contentView)
        #expect(clip.bounds.intersects(row.frame), "the active row is not in view after the first frame")
    }

    @Test func theFirstRowsWithTheActiveRowOnTopAreBuiltOnceToo() throws {
        let (sidebar, window, made) = Self.firstFrame(active: 0)
        defer { window.close() }
        #expect(made <= Self.budget(sidebar.list), "the first frame built \(made) row views (\(Self.placement(sidebar)))")
        #expect(sidebar.list.rowViews[.workspace(WorkspaceID("first-rows-0"))] != nil, "the active top row has no view")
    }

    /// Review of #34134 (P2): an active row already wholly in view in the first viewport does not move (close-focus.md
    /// rule 7). The first-viewport reveal scrolled with its 8 pt padding, so a row near the bottom edge moved up.
    @Test func anActiveRowAlreadyInTheFirstViewportDoesNotMove() throws {
        // The last workspace row wholly in the list at offset 0, read from the list's own layout (the section header
        // and the chrome above the rows count), with less than the 8 pt reveal padding below it.
        let (probe, probeWindow, _) = Self.firstFrame(active: 0)
        let clipHeight = probe.list.enclosingScrollView?.contentView.bounds.height ?? Self.height
        let whole = probe.list.displayed.rows.compactMap { row -> (Int, CGFloat)? in
            guard case let .workspace(id) = row.key, let index = Int(id.rawValue.split(separator: "-").last ?? ""),
                  row.y + row.height <= clipHeight else { return nil }
            return (index, row.y + row.height)
        }
        probeWindow.close()
        let (lastWhole, bottom) = try #require(whole.max { $0.1 < $1.1 }, "no workspace row is wholly in the list")
        try #require(lastWhole > 2, "the list shows \(clipHeight) pt")
        // A window just tall enough that the row ends 4 pt above the clip's bottom: wholly in view, inside the 8 pt padding.
        let height = Self.height - (clipHeight - bottom) + 4
        let (sidebar, window, _) = Self.firstFrame(active: lastWhole, height: height)
        defer { window.close() }
        let clip = try #require(sidebar.list.enclosingScrollView?.contentView)
        let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("first-rows-\(lastWhole)"))])
        #expect(clip.bounds.maxY - row.frame.maxY < SidebarLayout.revealPadding || clip.bounds.minY != 0,
                "the setup did not put the row inside the reveal padding (\(Self.placement(sidebar)))")
        #expect(clip.bounds.contains(row.frame), "the active row is not wholly in view (\(Self.placement(sidebar)))")
        #expect(clip.bounds.minY == 0, "the first frame scrolled to \(clip.bounds.minY) for row \(lastWhole), already in view")
    }

    /// Review of #34134 (P3): the app's usual order. The sidebar is made with no workspaces (`SidebarBridge`), the window
    /// lays it out, and the restored rows arrive after the list has a height (`applyKeepingViewport`'s first rows).
    @Test func rowsThatArriveAfterTheFirstLayoutAreBuiltOnce() throws {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [])])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: Self.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: Self.height)
        sidebar.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        _ = SidebarPerfCounters.report(reset: true)
        let ids = (0..<Self.count).map { WorkspaceID("first-rows-\($0)") }
        model.setSections([SidebarSection(kind: .machine(machine), nodes: ids.enumerated().map { index, id in
            .workspace(SidebarWorkspace(id: id, title: "project-\(index)", directory: "~/p\(index)"))
        })])
        model.activeWorkspaceID = ids[Self.active]
        // The launch shows the restored rows with no motion: profile 10 (cmux21, 100 workspaces) has them reach the list
        // through SidebarView.switchSpace, which calls reload(animated: false). A user's change in a shown list takes
        // the animated path, which this change does not touch.
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let made = SidebarPerfCounters.report(reset: true)["row_views_made"] ?? 0
        #expect(made <= Self.budget(sidebar.list), "the restored rows built \(made) row views (\(Self.placement(sidebar)))")
        let row = try #require(sidebar.list.rowViews[.workspace(ids[Self.active])], "the active row has no view (\(Self.placement(sidebar)))")
        let clip = try #require(sidebar.list.enclosingScrollView?.contentView)
        #expect(clip.bounds.intersects(row.frame))
    }

    /// Review of #34134 at 7e3916b0 (P2): a reload with no motion that jumps to a far reveal must still finish as the old
    /// instant scroll did (`realizeVisibleRows`): the old viewport's row views are parked, the group editor follows, the
    /// hover follows the scroll. Without it the top rows stayed in the list after a jump to row 80.
    @Test func aNoMotionJumpParksTheOldViewportsRows() throws {
        let (sidebar, window, _) = Self.firstFrame(active: 0)
        defer { window.close() }
        sidebar.model.activeWorkspaceID = WorkspaceID("first-rows-\(Self.active)")
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let clip = try #require(sidebar.list.enclosingScrollView?.contentView)
        let keep = clip.bounds.insetBy(dx: 0, dy: -(SidebarStyle.overscan + SidebarStyle.pruneMargin))
        let stale = sidebar.list.rowViews.filter { !$0.value.isHidden && !$0.value.frame.intersects(keep) }
        #expect(stale.isEmpty, "\(stale.count) row views of the old viewport stayed after the jump (\(Self.placement(sidebar)))")
        #expect(sidebar.list.rowViews[.workspace(WorkspaceID("first-rows-\(Self.active)"))] != nil, "the active row has no view")
    }
}
