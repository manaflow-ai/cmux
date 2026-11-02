import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-31: "INCREASE THE SIZE OF THESE BLUE DOTS ON THE SIDEBAR". The unread dot is 8 pt, as
/// Claude's and ChatGPT's, and every unread dot reads the one token.
@MainActor
struct SidebarUnreadDotSizeTests {
    @Test func unreadDotIsBiggerAndShared() {
        #expect(SidebarStyle.unreadDotSize > SidebarStyle.dotSize, "bigger than the 6 pt dot it replaced")
        let badge = UnreadBadgeView(frame: .zero)
        badge.configure(.dot)
        #expect(badge.preferredWidth == SidebarStyle.unreadDotSize)
    }

    @Test func defaultRowBadgeDrawsTheSharedDotSize() throws {
        // The static look (Reduce Motion) draws done as a green check, not the blue dot. Pin it off:
        // a runner with the system's Reduce Motion on (Blacksmith macOS) otherwise fails here.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        for look in [RowBadgeView.Look.plain, .corner, .stack] {
            let badge = RowBadgeView(frame: .zero)
            badge.configure([.success], look: look)
            badge.frame.size = NSSize(width: badge.preferredWidth, height: badge.cellSide)
            badge.layoutSubtreeIfNeeded()
            let glyph = try #require(badge.subviews.compactMap { $0 as? StatusIndicatorView }.first)
            #expect(glyph.indicator.plan.glyph == .mark(.vector(.dot)), "exercise the shipped blue-dot artwork")
            let ink = StaticStatusGlyph.dot.path(in: glyph.indicator.debugGlyphRect).boundingBoxOfPath
            #expect(abs(ink.width - SidebarStyle.unreadDotSize) < 0.01, "the glyph box is not the painted dot")
            #expect(abs(badge.convert(ink, from: glyph).midX - badge.bounds.midX) < 0.01)
            #expect(abs(badge.convert(ink, from: glyph).midY - badge.bounds.midY) < 0.01)
        }
    }

}
