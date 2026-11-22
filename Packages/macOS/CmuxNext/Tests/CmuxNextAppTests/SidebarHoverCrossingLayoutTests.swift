import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// HOVER PRELOAD 3 (cmux-ad m34, contract item 3): a pointer crossing a sidebar row records the hover and returns.
/// The row's layout (its hover controls) and its title marquee wait for the frame's own layout pass, which AppKit runs
/// before the commit that shows the hover, so the frame is the same. A synchronous layout of the row in every crossing
/// put main-thread work per crossing into a sweep across rows (missed refreshes in every arm of run f5825187).
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarHoverCrossingLayoutTests {
    /// A row with a title too long for it (the marquee's case), configured and laid out in a window.
    private func row() -> (WorkspaceRowView, NSWindow) {
        let ws = SidebarWorkspace(id: WorkspaceID("ws"), title: "A workspace name far too long to fit in one sidebar row of this width",
                                  lastActivity: Date())
        let content = SidebarLayoutOptions().rowContent(ws, machine: nil)
        let row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                             content: content)
        let view = WorkspaceRowView(key: row.key)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 28), styleMask: .borderless,
                              backing: .buffered, defer: true)
        // `close()` would release a window the test still holds (a segfault on the fleet).
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
        view.configure(ws, row: row, badgeStyle: .corner)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    @Test func aHoverCrossingLeavesTheRowsLayoutToTheFrame() {
        let (view, window) = row()
        view.isHovered = true
        #expect(view.needsLayout, "the hover turn laid the row out itself (a synchronous layout per crossing)")
        view.isHovered = false
        view.isHovered = true
        #expect(view.needsLayout)
        window.close()
    }

    @Test func theFramesLayoutStartsTheHoveredRowsMarquee() {
        let (view, window) = row()
        view.isHovered = true
        view.layoutSubtreeIfNeeded()
        // Active after the frame's layout, unless it cannot start at all (motion reduced or off on this host).
        #expect(view.title.isMarqueeActive || !view.title.startMarquee(), "the hovered row's clipped title did not scroll")
        view.isHovered = false
        #expect(!view.title.isMarqueeActive, "the marquee outlived the hover")
        window.close()
    }

    @Test func aRowLeftBeforeItsLayoutStartsNoMarquee() {
        let (view, window) = row()
        view.isHovered = true
        view.isHovered = false
        view.layoutSubtreeIfNeeded()
        #expect(!view.title.isMarqueeActive, "a row the pointer only crossed scrolled its title")
        window.close()
    }
}
