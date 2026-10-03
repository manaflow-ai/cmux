import AppKit
import Testing
@testable import CmuxNextSidebar

/// A count badge is a small rounded rectangle; the dot stays round.
@MainActor
@Suite struct UnreadBadgeShapeTests {
    @Test func aCountIsARoundedRectangleAndADotIsRound() throws {
        let badge = UnreadBadgeView(frame: CGRect(x: 0, y: 0, width: 24, height: 16))
        badge.configure(.count(3))
        badge.updateLayer()
        let layer = try #require(badge.layer)
        #expect(layer.cornerRadius > 0 && layer.cornerRadius <= 16 / 4)

        badge.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        badge.configure(.dot)
        badge.updateLayer()
        #expect(layer.cornerRadius == 4)
    }
}
