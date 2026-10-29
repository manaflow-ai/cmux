import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

@MainActor @Suite(.serialized)
struct SidebarWorkspaceDisclosureTests {
    @Test func anInactiveWindowsDisclosureAcceptsTheFirstClick() throws {
        let (model, sidebar, window) = SidebarTabGroupControlsTests.sidebar()
        defer { window.close() }
        let id = SidebarTabGroupControlsTests.shown
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        let button = row.disclosureButton
        let point = sidebar.list.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        let event = try SidebarIncrementalMatchesRebuildGapsTests.mouse(.leftMouseDown, at: point, in: sidebar.list)
        #expect(!window.isKeyWindow)
        #expect(button.acceptsFirstMouse(for: event), "the caret must fold on the first click, as its row does")
        for collapsed in [true, false, true, false] {
            #expect(button.accessibilityPerformPress())
            #expect(model.collapsedWorkspaces.contains(id) == collapsed)
            #expect(button.isAccessibilityExpanded() == !collapsed)
            #expect(button.icon == (collapsed ? .disclosureFolded : .disclosureExpanded))
            let tab = SidebarRowKey.tab(id, SidebarTabGroupControlsTests.first)
            #expect((sidebar.list.displayed.row(for: tab) == nil) == collapsed)
        }
    }

    @Test(arguments: [CGFloat(260), 400])
    func theCaretStaysBesideAShortNameOnHoverAndResize(_ width: CGFloat) throws {
        let (_, sidebar, window) = SidebarTabGroupControlsTests.sidebar()
        defer { window.close() }
        sidebar.frame.size.width = width
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let row = try #require(sidebar.list.rowViews[.workspace(SidebarTabGroupControlsTests.shown)] as? WorkspaceRowView)
        var caretX: CGFloat?
        row.layoutSubtreeIfNeeded()
        let clickPoint = NSPoint(x: row.frame.minX + row.disclosureButton.frame.midX,
                                y: row.frame.minY + row.disclosureButton.frame.midY)
        for hovered in [false, true, false] {
            row.isHovered = hovered
            row.layoutSubtreeIfNeeded()
            let textEnd = row.title.frame.minX + min(row.title.frame.width, row.title.intrinsicContentSize.width)
            #expect(abs(row.disclosureButton.frame.minX - textEnd - Metrics.space1) < 0.5,
                    "the caret is separated from the name by empty row width")
            if let caretX { #expect(abs(row.disclosureButton.frame.minX - caretX) < 0.5) }
            caretX = row.disclosureButton.frame.minX
            #expect(row.hitTest(clickPoint) === row.disclosureButton, "hover moved the caret away from the pointer")
            if hovered {
                #expect(row.disclosureButton.frame.maxX <= row.closeButton.frame.minX)
            }
        }
    }
}
