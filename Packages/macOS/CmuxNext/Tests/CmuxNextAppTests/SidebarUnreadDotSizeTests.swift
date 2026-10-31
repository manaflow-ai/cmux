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
}
