import AppKit
import Testing
@testable import CmuxNextSidebar

/// Drag auto-scroll runs only while the pointer is inside an edge zone.
@MainActor @Suite struct AutoscrollTests {
    /// A sidebar tall enough to show a few rows, with more content below.
    func makeSidebar() -> SidebarView {
        var sections = fixture()
        let extra = (0..<40).map { SidebarNode.workspace(w("extra\($0)")) }
        sections[1].nodes.append(contentsOf: extra)
        let view = SidebarView(model: SidebarModel(sections: sections, activeWorkspaceID: id("a")))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        return view
    }

    func windowPoint(_ list: SidebarListView, fraction: CGFloat) -> NSPoint {
        let visible = list.visibleRect
        return list.convert(NSPoint(x: visible.midX, y: visible.minY + visible.height * fraction), to: nil)
    }

    @Test func externalDragInMiddleDoesNotRunTimer() {
        let sidebar = makeSidebar()
        let list = sidebar.list
        _ = list.externalDragMoved(windowPoint: windowPoint(list, fraction: 0.5), sourceMachine: .local)
        #expect(list.external != nil)
        #expect(list.autoscrollLink == nil)
        list.externalDragExited()
    }

    @Test func externalDragNearEdgeRunsTimerAndStopsWhenLeaving() {
        let sidebar = makeSidebar()
        let list = sidebar.list
        _ = list.externalDragMoved(windowPoint: windowPoint(list, fraction: 0.99), sourceMachine: .local)
        #expect(list.autoscrollLink != nil)
        _ = list.externalDragMoved(windowPoint: windowPoint(list, fraction: 0.5), sourceMachine: .local)
        #expect(list.autoscrollLink == nil)
        list.externalDragExited()
    }
}
