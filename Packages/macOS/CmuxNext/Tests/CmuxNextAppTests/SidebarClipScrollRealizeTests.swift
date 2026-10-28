import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar list realizes rows as its clip scrolls and follows the clip's width as it resizes, pushed
/// from the clip itself (before, from NotificationCenter observers of the clip).
/// The edge fade and the scroll fit share that clip, so the sidebar's pushes must
/// survive them attaching.
@MainActor @Suite(.serialized) struct SidebarClipScrollRealizeTests {
    private static let count = 200

    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let nodes = (0..<count).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace \($0)")) }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        return sidebar
    }

    @Test func theClipIsTheSharedGeometryClip() {
        let sidebar = Self.sidebar()
        let clip = sidebar.scrollView.contentView
        #expect(clip is ScrollGeometryClipView)
        #expect(ScrollGeometryClipView.install(in: sidebar.scrollView) === clip, "a later client keeps the clip")
    }

    @Test func scrollingTheClipRealizesTheRowsItShows() {
        let sidebar = Self.sidebar()
        let last = SidebarRowKey.workspace(WorkspaceID("ws-\(Self.count - 1)"))
        #expect(sidebar.list.rowViews[last] == nil, "the last row starts far below the viewport")
        let clip = sidebar.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: sidebar.list.frame.height - clip.bounds.height))
        #expect(sidebar.list.rowViews[last] != nil)
    }

    /// The scroll view tiles its clip to a new width with no sidebar layout pass (which would fit the
    /// list itself): only the clip's push can fit it.
    @Test func resizingTheClipFitsTheListToItsWidth() {
        let sidebar = Self.sidebar()
        let scrollView = sidebar.scrollView
        let before = sidebar.list.frame.width
        scrollView.setFrameSize(NSSize(width: scrollView.frame.width - 60, height: scrollView.frame.height))
        scrollView.tile()
        let clipWidth = scrollView.contentView.bounds.width
        #expect(clipWidth != before)
        #expect(sidebar.list.frame.width == clipWidth)
    }
}
