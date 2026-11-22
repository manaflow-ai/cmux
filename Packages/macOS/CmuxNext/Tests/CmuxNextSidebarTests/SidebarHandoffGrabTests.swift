import AppKit
import Testing
@testable import CmuxNextSidebar

/// Dogfood nxdog13 ("my mouse's relative position ... should never change"),
/// sidebar side: a workspace row dragged sideways out of the sidebar is
/// handed to the App's window drag with the point the user pressed, not the
/// pointer's offset from the row at hand-off (by then beyond the sidebar
/// edge, so outside the row).
@MainActor @Suite struct SidebarHandoffGrabTests {
    @Test func theHandoffCarriesThePressedPointInTheRow() throws {
        let sidebar = SidebarView(model: SidebarModel(sections: fixture(), activeWorkspaceID: id("a")))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        let list = sidebar.list
        list.reload(animated: false)
        var offer: SidebarDragHandoff?
        list.onDragHandoff = { offer = $0; return true }

        let row = try #require(list.displayed.row(for: .workspace(id("b"))))
        let rowFrame = list.frame(for: row)
        let pressed = NSPoint(x: rowFrame.minX + 40, y: rowFrame.minY + 7)
        list.beginDrag(SidebarListView.Press(key: .workspace(id("b")), point: pressed))
        #expect(list.drag != nil)
        // Sideways out of the sidebar, a little lower than the press.
        list.updateDrag(windowPoint: list.convert(NSPoint(x: pressed.x + 300, y: pressed.y + 5), to: nil))
        let handoff = try #require(offer)
        // Pressed 40 pt in and 7 pt below the row's top: y up from its bottom.
        #expect(abs(handoff.grabOffset.x - 40) < 0.5, "x \(handoff.grabOffset.x)")
        #expect(abs(handoff.grabOffset.y - (rowFrame.height - 7)) < 0.5, "y \(handoff.grabOffset.y)")
    }
}
