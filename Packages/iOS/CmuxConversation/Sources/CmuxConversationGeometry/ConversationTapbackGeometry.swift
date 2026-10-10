import CoreGraphics

/// The tapback badge Messages hangs on a bubble, read from ChatKit's
/// `CKTapbackPlatterView` in Messages on iOS 26.5 and 27.0 (iPhone 17 Pro,
/// Large text): a 34 pt disc with a 10 pt and a 5 pt dot trailing down and
/// away from the bubble, each ringed by 0.5 pt of the page color
/// (`TapbackPlatterPunchOutView`s of 35, 11 and 6 pt) so the badge stands off
/// the bubble it overlaps. The glyph is 32 pt, centered in the disc.
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
}
