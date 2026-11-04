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

    /// A reacted reply's badge sits between its quote and its bubble; the row
    /// must not rise, or the quote draws over the bubble above (user's
    /// iPhone: a reply quote on top of "lunch? thinking ramen").
    @Test func aBadgeBelowAQuoteDoesNotRiseBesideTheRowAbove() {
        let above = CGRect(x: 87, y: 0, width: 284, height: 40.33)
        let badge = CGRect(x: 440, y: 50, width: 48, height: 44)
        #expect(ConversationTapbackGeometry.rise(badge: badge, rowAbove: above, badgeTopsRow: true) == ConversationTapbackGeometry.rowGrowth)
        #expect(ConversationTapbackGeometry.rise(badge: badge, rowAbove: above, badgeTopsRow: false) == 0)
        // Overlapping sideways never rises.
        #expect(ConversationTapbackGeometry.rise(badge: badge.offsetBy(dx: -150, dy: 0), rowAbove: above, badgeTopsRow: true) == 0)
    }

    /// The badge rides above its own row, over the row before it: in the
    /// iOS 27 sim "looking" (row 488...563) hangs its badge at 282.67, 488
    /// (37.49 x 43.44), while "rip" (465.33...512.5) owns y < 512.5. A tap on
    /// the badge's upper half must still reach "looking" (Messages opens the
    /// reactions from anywhere on the tapback).
    @Test func tapOnABadgeOverTheRowAboveFindsTheBadgesRow() {
        let badges: [CGRect?] = [nil, CGRect(x: 282.67, y: 488, width: 37.49, height: 43.44)]
        #expect(ConversationTapbackGeometry.badgeOwner(at: CGPoint(x: 301, y: 500), badges: badges) == 1)
        #expect(ConversationTapbackGeometry.badgeOwner(at: CGPoint(x: 301, y: 527), badges: badges) == 1)
        // Slop of 6 pt around the badge, as the bubble's own check had.
        #expect(ConversationTapbackGeometry.badgeOwner(at: CGPoint(x: 277, y: 485), badges: badges) == 1)
        #expect(ConversationTapbackGeometry.badgeOwner(at: CGPoint(x: 200, y: 500), badges: badges) == nil)
    }
}

/// Messages 27 reaction detail (iOS 27.0 sim, iPhone 17 Pro, light, one
/// reactor "KB" with a heart): a glass card 138.33...262 x 61.67...184.33
/// (radius ~31) under the status bar, a white 50 pt thought bubble 176...226
/// x 71...121 with the 32 pt-box tapback, a dot trailing below it, and a
/// 30.67 pt avatar at 185.67, 140.67.
@Suite struct ReactionDetailCardGeometryTests {
    @Test func oneReactorCardMatchesMessages27() {
        let card = ReactionDetailCardGeometry.card(reactorCount: 1, maxWidth: 370, width: 402, safeTop: 62)
        #expect(abs(card.minX - 138.33) < 1)
        #expect(abs(card.maxX - 262) < 1)
        #expect(abs(card.minY - 61.67) < 0.5)
        #expect(abs(card.height - 122.67) < 0.5)
        let column = ReactionDetailCardGeometry.column(index: 0, reactorCount: 1, cardWidth: card.width)
        #expect(abs(card.minX + column.bubble.minX - 176) < 0.5)
        #expect(abs(card.minY + column.bubble.minY - 71) < 0.5)
        #expect(column.bubble.width == 50)
        #expect(abs(card.minX + column.avatar.minX - 185.67) < 0.5)
        #expect(abs(card.minY + column.avatar.minY - 140.67) < 0.5)
        #expect(abs(column.avatar.width - 30.67) < 0.05)
        #expect(ReactionDetailCardGeometry.cornerRadius >= 30 && ReactionDetailCardGeometry.cornerRadius <= 32)
    }

    @Test func manyReactorsScrollWithinTheScreen() {
        let card = ReactionDetailCardGeometry.card(reactorCount: 12, maxWidth: 370, width: 402, safeTop: 62)
        #expect(card.width == 370)
        #expect(abs(card.midX - 201) < 0.01)
    }
}
