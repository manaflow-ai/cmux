import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// `sidebar.workspaceRow.unreadDot` `neutral` draws a done row's unread dot in the theme's secondary
/// text color, the Claude Code app's gray session dots (customize-app-profiles); `blue`, the default,
/// keeps the status blue. Only the unread dot changes.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRowUnreadDotTests {
    private static func row(_ dot: WorkspaceRowUnreadDot?) -> (WorkspaceRowView, NSWindow) {
        var ws = SidebarWorkspace(id: WorkspaceID("ws"), title: "Fix the build", lastActivity: Date(),
                                  agentWorking: false, activity: .success)
        ws.unread = .dot
        var options = SidebarLayoutOptions()
        if let dot { options.workspaceRow.unreadDot = dot }
        let content = options.rowContent(ws, machine: nil)
        let row = SidebarRow(key: .workspace(ws.id), y: 0, height: 28, section: .pinned, group: nil, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil,
                             content: content)
        let view = WorkspaceRowView(key: row.key)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 28), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        view.configure(ws, row: row, badgeStyle: .corner)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private static func glyphs(_ view: WorkspaceRowView) -> [StatusIndicatorView] {
        view.rowBadge.subviews.compactMap { $0 as? StatusIndicatorView }
    }

    @Test func blueIsTheDefault() {
        #expect(SidebarLayoutOptions().workspaceRow.unreadDot == .blue)
        let (view, window) = Self.row(nil)
        defer { window.close() }
        #expect(view.rowBadge.unreadColor == nil)
        #expect(!Self.glyphs(view).isEmpty)
        #expect(Self.glyphs(view).allSatisfy { $0.unreadColor == nil && $0.usesStatusColors })
    }

    @Test func neutralPaintsTheDotInSecondaryText() {
        let (view, window) = Self.row(.neutral)
        defer { window.close() }
        #expect(view.rowBadge.unreadColor == Palette.textSecondary)
        #expect(!Self.glyphs(view).isEmpty)
        #expect(Self.glyphs(view).allSatisfy { $0.unreadColor == Palette.textSecondary })
    }
}
