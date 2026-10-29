import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextWakeups
import Testing

/// CmuxNextApp's invalidation discipline (plans/cmux-next/chrome-parity/p03-rendering.md R4, task
/// 064): a view asks for a layout or a redraw only when a value it lays out or draws changed. Chrome
/// marks a LayoutObject dirty only on a style or geometry change (`LayoutObject::SetNeedsLayout`
/// callers compare first, third_party/blink/renderer/core/layout/layout_object.cc).
@MainActor @Suite(.serialized) struct AppInvalidationDisciplineTests {
    /// The resize strip recolors its line on a theme change; the line stays where it is.
    @Test func theResizeStripRecolorsWithoutALayout() {
        let handle = RightSidebarResizeHandle(frame: NSRect(x: 0, y: 0, width: RightSidebarResizeHandle.grabWidth, height: 640))
        handle.layoutSubtreeIfNeeded()
        handle.viewDidChangeEffectiveAppearance()
        #expect(!handle.needsLayout, "a recolor lays nothing out")
        handle.edge = .maxX
        #expect(handle.needsLayout, "the line moves to the other edge")
    }

    /// A notification row selected again paints nothing; a new selection repaints its fill.
    @Test func aNotificationRowSelectedAgainPaintsNothing() {
        let row = NotificationsPanelRow(id: "n1", title: "Build finished", subtitle: nil, body: "All green", level: .info,
                                        workspaceTitle: "cmux", createdAt: Date(timeIntervalSince1970: 0), unread: true,
                                        surface: nil, terminal: nil)
        let view = NotificationRowView(row: row, now: Date(timeIntervalSince1970: 60), node: VisibilityNode(root: "test.row", own: .visible),
                                       callbacks: .init(open: {}, dismiss: {}, menu: { NSMenu() }))
        view.needsDisplay = false
        view.isSelected = false
        #expect(!view.needsDisplay, "the same selection: no paint")
        view.isSelected = true
        #expect(view.needsDisplay, "selected: the fill paints")
    }
}
