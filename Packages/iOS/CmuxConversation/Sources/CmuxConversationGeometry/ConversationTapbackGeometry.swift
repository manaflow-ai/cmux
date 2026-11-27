import CoreGraphics

/// The tapback badge Messages hangs on a bubble, read from ChatKit's
/// `CKTapbackPlatterView` in Messages on iOS 26.5 and 27.0 (iPhone 17 Pro,
/// Large text): a 34 pt disc with a 10 pt and a 5 pt dot trailing down and
/// away from the bubble, each ringed by 0.5 pt of the page color
/// (`TapbackPlatterPunchOutView`s of 35, 11 and 6 pt) so the badge stands off
/// the bubble it overlaps. The glyph is 32 pt, centered in the disc.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationTapbackGeometry {
    /// The platter's box (outline circles included), dots toward the leading edge.
    public static let platterSize = CGSize(width: 37.49, height: 43.44)
    /// Outline circles in the platter (disc, medium dot, small dot), as
    /// ChatKit lays them out when the dots trail to the left (a badge on a
    /// sent bubble's top-left corner).
    public static let outlineCircles: [CGRect] = [
        CGRect(x: 2.49, y: 0, width: 35, height: 35),
        CGRect(x: 3.46, y: 27.17, width: 11, height: 11),
        CGRect(x: -0.5, y: 37.94, width: 6, height: 6),
    ]
    /// The colored shapes sit 0.5 pt inside their outlines.
    public static let outlineWidth: CGFloat = 0.5
    public static let glyphSize: CGFloat = 32
    /// The platter's origin from the bubble body's top corner on the badge
    /// side: 17 pt outside it and 27.78 pt above, which puts the disc's center
    /// 2.99 pt inside the corner and 10.28 pt above the bubble.
    public static let platterOffsetFromCorner = CGPoint(x: -17.0, y: -27.78)
    /// How much lower a reacted bubble sits than it would without the badge:
    /// Messages leaves 37.78 pt between the previous body and this one
    /// (10 pt between runs plus the platter's rise), or plain 10 pt when the
    /// badge clears the previous bubble sideways.
    public static let rowGrowth: CGFloat = 27.78

    /// How far a reacted row rises into the gap above it. A badge that
    /// clears the row above sideways rises beside it instead of pushing the
    /// bubble down (Messages, iOS 27.0: "Ha ha" under a narrower bubble
    /// keeps the plain 10 pt gap). `badgeTopsRow` is false when something sits
    /// above the badge in the row (a reply quote, a sender name).
    public static func rise(badge: CGRect, rowAbove: CGRect, badgeTopsRow: Bool) -> CGFloat {
        guard badgeTopsRow else { return 0 }
        return badge.maxX <= rowAbove.minX || badge.minX >= rowAbove.maxX ? rowGrowth : 0
    }

    /// The platter's frame for a bubble body `body`. Sent bubbles (`leading`
    /// false) carry it on their top-left corner with the dots trailing left;
    /// received ones on the top-right, mirrored.
    public static func platterFrame(forBody body: CGRect, onTrailingCorner: Bool) -> CGRect {
        let size = platterSize
        let y = body.minY + platterOffsetFromCorner.y
        let x = onTrailingCorner
            ? body.maxX - platterOffsetFromCorner.x - size.width
            : body.minX + platterOffsetFromCorner.x
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// `outlineCircles` in platter coordinates, mirrored when the badge sits
    /// on a bubble's trailing (right) corner so the dots trail right.
    public static func circles(mirrored: Bool) -> [CGRect] {
        guard mirrored else { return outlineCircles }
        return outlineCircles.map { CGRect(x: platterSize.width - $0.maxX, y: $0.minY, width: $0.width, height: $0.height) }
    }

    /// How far outside its platter a tap still counts as on the badge.
    public static let badgeTapSlop: CGFloat = 6

    /// The row whose badge a tap at `point` lands on, given each row's badge
    /// frame (nil without one) in the same space. Badges ride above their own
    /// row, over the row before it, so the row under the finger isn't
    /// necessarily the badge's; the later row wins where badges overlap, as
    /// it draws on top.
    public static func badgeOwner(at point: CGPoint, badges: [CGRect?]) -> Int? {
        badges.indices.reversed().first { index in
            badges[index].map { $0.insetBy(dx: -badgeTapSlop, dy: -badgeTapSlop).contains(point) } ?? false
        }
    }
}

/// The reaction detail Messages shows when a tapback is tapped: a glass card
/// under the status bar with one column per reactor, their tapback in a
/// white thought bubble over their avatar. Measured on iOS 27.0 (iPhone 17
/// Pro, light, one reactor): card 123.67 x 122.67 at the safe top - 0.33,
/// radius ~31; bubble 50 pt at 9.33 from the card's top; dots below it;
/// 30.67 pt avatar 79 pt down. Multi-reactor spacing isn't observable in the
/// simulator; each reactor gets a column of the one-reactor width.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ReactionDetailCardGeometry {
    public static let columnSize = CGSize(width: 123.67, height: 122.67)
    public static let topOffset: CGFloat = -0.33
    public static let cornerRadius: CGFloat = 31
    public static let bubbleDiameter: CGFloat = 50
    public static let bubbleTop: CGFloat = 9.33
    /// The tapback inside the bubble, in a badge glyph's 32 pt box scaled
    /// with the bubble (50 / 35).
    public static let glyphSize: CGFloat = 45
    /// Trailing dots under the bubble, centered: a nub and a small dot.
    public static let mediumDot = CGSize(width: 11, height: 11)
    public static let mediumDotCenterY: CGFloat = 61.83
    public static let smallDot = CGSize(width: 5.33, height: 5.33)
    public static let smallDotCenterY: CGFloat = 72.33
    public static let avatarDiameter: CGFloat = 30.67
    public static let avatarTop: CGFloat = 79

    public struct Column: Equatable, Sendable {
        public var bubble: CGRect
        public var glyph: CGRect
        public var mediumDot: CGRect
        public var smallDot: CGRect
        public var avatar: CGRect
    }

    /// The card's frame, centered, no wider than `maxWidth` (it scrolls).
    public static func card(reactorCount: Int, maxWidth: CGFloat, width: CGFloat, safeTop: CGFloat) -> CGRect {
        let cardWidth = min(CGFloat(max(reactorCount, 1)) * columnSize.width, maxWidth)
        return CGRect(x: (width - cardWidth) / 2, y: safeTop + topOffset, width: cardWidth, height: columnSize.height)
    }

    /// Content width of all columns (the scroll content).
    public static func contentWidth(reactorCount: Int) -> CGFloat {
        CGFloat(max(reactorCount, 1)) * columnSize.width
    }

    /// Column `index`'s pieces in the card's content space. A lone column
    /// centers in the card.
    public static func column(index: Int, reactorCount: Int, cardWidth: CGFloat) -> Column {
        let content = contentWidth(reactorCount: reactorCount)
        let lead = max(0, (cardWidth - content) / 2)
        let midX = lead + (CGFloat(index) + 0.5) * columnSize.width
        let bubble = CGRect(x: midX - bubbleDiameter / 2, y: bubbleTop, width: bubbleDiameter, height: bubbleDiameter)
        return Column(
            bubble: bubble,
            glyph: CGRect(x: midX - glyphSize / 2, y: bubble.midY - glyphSize / 2, width: glyphSize, height: glyphSize),
            mediumDot: CGRect(x: midX - mediumDot.width / 2, y: mediumDotCenterY - mediumDot.height / 2, width: mediumDot.width, height: mediumDot.height),
            smallDot: CGRect(x: midX - smallDot.width / 2, y: smallDotCenterY - smallDot.height / 2, width: smallDot.width, height: smallDot.height),
            avatar: CGRect(x: midX - avatarDiameter / 2, y: avatarTop, width: avatarDiameter, height: avatarDiameter)
        )
    }
}
