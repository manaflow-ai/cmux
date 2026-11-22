import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-22, on his NIGHTLY (a blue dot with the ✕ drawn over it): "not sure why this issue isn't fixed yet in
/// this nightly. the dot shouldnt show up when i hover; the cross should be there instead. liekwise with the other
/// icons. ive already said this".
///
/// The earlier fixes (#48411, #49582) hid the marks in the row's layout, and their tests ran the layout only. In the
/// app a hover also repaints the row's fill, and that display pass (`updateLayer` → `updateNeedsYouGlow`) set the
/// unread dot, the row badge and the status mark back to full opacity, so the dot drew under the ✕ again. Every check
/// here hovers, runs the layout and then the display pass, as the app does, and asks the one rule (`HoverSwap`): no
/// mark draws while an action of its row does.
@MainActor @Suite(.serialized, .closesItsWindows)
struct HoverSwapRuleTests {
    typealias Marks = SidebarRowCloseClearsMarksTests.Marks

    /// The marks with a status Leo named: the blue dot, an unread count, the spinner, the spinner with unread, the error
    /// mark, and everything at once.
    static let statusMarks: [Marks] = [.unreadDot, .unreadCount, .running, .runningUnread, .error, .everything]

    /// Hover (or leave) `row`, then lay it out and paint it, as a pointer crossing does in the app.
    static func hover(_ row: SidebarRowView, _ on: Bool) {
        row.isHovered = on
        row.layoutSubtreeIfNeeded()
        row.updateLayer()
        row.layoutSubtreeIfNeeded() // a display pass that asked for a layout gets it, as the next frame would
        row.updateLayer()
    }

    @Test(arguments: statusMarks, SidebarRowBadgeStyle.allCases)
    func aHoveredWorkspaceRowDrawsNoMarkBesideItsActionsAfterTheDisplayPass(_ marks: Marks, _ style: SidebarRowBadgeStyle) throws {
        Motion.reduceMotionOverride = true // the marks clear at once instead of fading out
        defer { Motion.reduceMotionOverride = nil }
        for spot in SidebarRowCloseSpot.allCases {
            try SidebarRowCloseSpotTests.withCloseSpot(spot) {
                let (sidebar, window) = SidebarRowCloseClearsMarksTests.sidebar(marks, style: style)
                defer { window.close() }
                sidebar.list.model.workspacePin = (isPinned: { _ in false }, toggle: { _ in })
                sidebar.list.contextMenuProvider = { _ in NSMenu() }
                window.orderFrontRegardless()
                sidebar.renderNow()
                let row = try #require(sidebar.list.rowViews[.workspace(SidebarRowCloseClearsMarksTests.row)] as? WorkspaceRowView)
                row.wire(SidebarRowCloseClearsMarksTests.row, in: sidebar.list)
                Self.hover(row, false)
                let resting = SidebarHoverReplacesMarksTests.statusMarksDrawn(in: row)
                try #require(!resting.isEmpty, "\(spot) \(marks): the row draws no mark at rest")

                Self.hover(row, true)
                try #require(row.closeSlot.made.map { !$0.isHidden && $0.alphaValue > 0 } == true, "\(spot) \(marks): no ✕ on the hovered row")
                #expect(HoverSwap.violations(in: row).isEmpty, "\(spot), \(style), \(marks): \(HoverSwap.violations(in: row))")
                #expect(SidebarHoverReplacesMarksTests.statusMarksDrawn(in: row).isEmpty,
                        "\(spot), \(style), \(marks): \(SidebarHoverReplacesMarksTests.statusMarksDrawn(in: row)) draw beside the ✕")

                // The hover ends: the layout, not the display pass, brings every mark back.
                Self.hover(row, false)
                #expect(SidebarHoverReplacesMarksTests.statusMarksDrawn(in: row) == resting,
                        "\(spot) \(marks): \(resting) at rest, \(SidebarHoverReplacesMarksTests.statusMarksDrawn(in: row)) after the hover")
            }
        }
    }

    /// A group header with unread workspaces: its ⋮, + and Unpin replace the unread count and the group's count.
    @Test func aHoveredGroupHeaderDrawsNoUnreadBesideItsActions() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (header, window) = try GroupHeaderHoverRevealTests.header()
        defer { window.close() }
        let badge = try #require(header.subviews.compactMap { $0 as? UnreadBadgeView }.first)
        badge.configure(.count(3))
        Self.hover(header, false)
        try #require(!badge.isHidden && badge.alphaValue > 0, "the header draws no unread count at rest")
        Self.hover(header, true)
        #expect(HoverSwap.violations(in: header).isEmpty, "\(HoverSwap.violations(in: header))")
        #expect(badge.alphaValue == 0, "the unread count draws beside the header's actions")
        Self.hover(header, false)
        #expect(badge.alphaValue == 1, "the unread count did not come back after the hover")
    }

    /// The checker itself: a mark and an action drawn together in one group is a violation; either one alone is not.
    @Test func theRuleCatchesAMarkDrawnBesideAnAction() {
        let group = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        group.wantsLayer = true
        let action = NSView(frame: NSRect(x: 170, y: 6, width: 16, height: 16))
        let mark = NSView(frame: NSRect(x: 174, y: 10, width: 8, height: 8))
        [action, mark].forEach(group.addSubview)
        HoverSwap.tag([action], .action, in: group)
        HoverSwap.tag([mark], .mark, in: group)
        #expect(HoverSwap.violations(in: group).count == 1)
        HoverSwap.hide([mark])
        #expect(HoverSwap.violations(in: group).isEmpty)
        mark.alphaValue = 1
        action.isHidden = true
        #expect(HoverSwap.violations(in: group).isEmpty)
    }
}
