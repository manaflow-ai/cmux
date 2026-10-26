import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar list realizes rows as its clip scrolls and follows the clip's width as it resizes, pushed
/// from the clip itself (p03-rendering-039; before, from `boundsDidChangeNotification` and
/// `frameDidChangeNotification` observers).
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

    @Test func theClipIsTheSidebarsOwn() {
        #expect(Self.sidebar().scrollView.contentView is ScrollClipView)
    }

    @Test func scrollingTheClipRealizesTheRowsItShows() {
        let sidebar = Self.sidebar()
        let last = SidebarRowKey.workspace(WorkspaceID("ws-\(Self.count - 1)"))
        #expect(sidebar.list.rowViews[last] == nil, "the last row starts far below the viewport")
        let clip = sidebar.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: sidebar.list.frame.height - clip.bounds.height))
        #expect(sidebar.list.rowViews[last] != nil)
    }

    @Test func resizingTheClipFitsTheListToItsWidth() {
        let sidebar = Self.sidebar()
        sidebar.frame.size.width = 300
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.list.frame.width == sidebar.scrollView.contentView.bounds.width)
    }
}
