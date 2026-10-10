import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// Reference frames are `CKTapbackPlatterView` and its punch-out views from
/// Messages on iOS 27.0 (402 pt, light), a heart on "Heart this one" (body
/// 251.00, 259.67, 135 x 40.33).
@Suite struct ConversationTapbackGeometryTests {
    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.02 && abs(a.minY - b.minY) < 0.02 && abs(a.width - b.width) < 0.02 && abs(a.height - b.height) < 0.02
    }

    @Test func platterSitsOnTheSentBubblesTopLeftCorner() {
        let body = CGRect(x: 251, y: 259.67, width: 135, height: 40.33)
        let platter = ConversationTapbackGeometry.platterFrame(forBody: body, onTrailingCorner: false)
        #expect(close(platter, CGRect(x: 234.00, y: 231.89, width: 37.49, height: 43.44)))
        let disc = ConversationTapbackGeometry.circles(mirrored: false)[0].offsetBy(dx: platter.minX, dy: platter.minY)
        #expect(close(disc, CGRect(x: 236.49, y: 231.89, width: 35, height: 35)))
        let medium = ConversationTapbackGeometry.circles(mirrored: false)[1].offsetBy(dx: platter.minX, dy: platter.minY)
        #expect(close(medium, CGRect(x: 237.46, y: 259.06, width: 11, height: 11)))
        let small = ConversationTapbackGeometry.circles(mirrored: false)[2].offsetBy(dx: platter.minX, dy: platter.minY)
        #expect(close(small, CGRect(x: 233.50, y: 269.83, width: 6, height: 6)))
    }

    @Test func receivedBubblesMirrorTheBadge() {
        let body = CGRect(x: 16, y: 300, width: 135, height: 40.33)
        let platter = ConversationTapbackGeometry.platterFrame(forBody: body, onTrailingCorner: true)
        let disc = ConversationTapbackGeometry.circles(mirrored: true)[0].offsetBy(dx: platter.minX, dy: platter.minY)
        // The disc's center sits 2.99 pt inside the top-right corner.
        #expect(abs(disc.midX - (body.maxX - 2.99)) < 0.02)
        #expect(abs(disc.midY - (body.minY - 10.28)) < 0.02)
        let small = ConversationTapbackGeometry.circles(mirrored: true)[2].offsetBy(dx: platter.minX, dy: platter.minY)
        #expect(small.midX > body.maxX)
    }
}
