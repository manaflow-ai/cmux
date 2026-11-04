import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// REOPEN-F7: a reopened window's first layout pass (`WindowActivation.show` -> `ShellWindow.layoutIfNeeded`) took about
/// 21 ms profiled at 24 workspaces and 36 ms at 100 (profile 10), most of it in the sidebar's row views and their
/// controls. Chrome's first paint lays out only what is in the viewport, once. The floor here: before the first frame,
/// each row view in the list is laid out once, and only the rows in view plus the overscan have views.
///
/// Counted with `LayoutPassGuard` (`-[NSView layout]` calls per view class), so the result is the same on each run.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFirstFrameLayoutPassTests {
    private static let count = 100, active = 80, height: CGFloat = 640

    /// A window's first frame, in the order WindowController makes it: the sidebar is made, the window lays it out,
    /// the first render runs, the window shows and displays. Returns the sidebar, its window, and the `layout()`
    /// calls of workspace row views from the sidebar's creation through the first display.
    private static func firstFrame() -> (SidebarView, NSWindow, rowLayouts: Int) {
        _ = NSApplication.shared
        LayoutPassGuard.shared.install()
        let before = rowLayoutCalls()
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ids = (0..<count).map { WorkspaceID("first-pass-\($0)") }
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
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        window.displayIfNeeded()
        return (sidebar, window, rowLayoutCalls() - before)
    }

    /// `layout()` calls of `WorkspaceRowView` since launch (the guard counts per class).
    private static func rowLayoutCalls() -> Int {
        LayoutPassGuard.shared.passesByClass.first { $0.viewClass == String(describing: WorkspaceRowView.self) }?.passes ?? 0
    }

    @Test func eachRowViewIsLaidOutOnceBeforeTheFirstFrame() throws {
        let (sidebar, window, rowLayouts) = Self.firstFrame()
        defer { window.close() }
        let rows = sidebar.list.rowViews.values.filter { $0 is WorkspaceRowView && !$0.isHidden }.count
        try #require(rows > 0, "the first frame has no workspace row view")
        #expect(rowLayouts <= rows, "the first frame ran WorkspaceRowView.layout \(rowLayouts) times for \(rows) row views")
    }
}
