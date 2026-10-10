import CoreGraphics

/// The iOS composer row: the "+" glass circle, the glass field, and the send
/// capsule inside the field.
///
/// The constants are Messages' own (ChatKit `CKUIBehaviorPhone` on iOS 26.5)
/// and match its pixels on iOS 26.5 and 27.0, iPhone 17 Pro and Pro Max:
/// `entryViewPlusButtonSize` 40, `entryViewPlusButtonToTextFieldPadding` 12,
/// `entryViewConcentricPadding` 28 (the side inset with no keyboard),
/// `sendButtonSize` 38 by 28, `entryViewSendButtonCoverSpace` 6.33 (the send
/// capsule's trailing inset in the field), `entryContentViewTextLeftOffset`
/// 16.
///
/// With the keyboard up Messages drops the concentric padding and uses the
/// system layout margin instead: 16 pt on a 402 pt iPhone, 20 pt on a 440 pt
/// one. Both the "+" and the field's trailing edge use that inset.
public enum ComposerBarGeometry {
    /// The "+" glass circle's diameter.
    public static let plusDiameter: CGFloat = 40
    /// Gap between the "+" circle and the field.
    public static let plusToFieldGap: CGFloat = 12
    /// Side inset of the "+" and the field with no keyboard.
    public static let restSideInset: CGFloat = 28
    /// The send capsule.
    public static let sendSize = CGSize(width: 38, height: 28)
    /// The send capsule's trailing inset inside the field.
    public static let sendTrailingInset: CGFloat = 19.0 / 3
    /// Where the field's text starts, from the field's leading edge.
    public static let textLeadingInset: CGFloat = 16
    /// The "+" glyph: SF Symbol `plus`, regular weight, medium scale, 15.33
    /// pt of ink with a 1.33 pt stroke. It renders pixel for pixel as
    /// Messages' (mean difference 0.01 of 255 over the circle on iOS 26.5).
    /// A button's default symbol scale is large, so the scale is explicit.
    public static let plusSymbolPointSize: CGFloat = 19
    /// The "+" glyph's vertical offset from the circle's center. iOS 27's
    /// `plus` image is 0.67 pt taller than 26.5's, and Messages 27 draws the
    /// glyph one pixel higher than a centered image (26.5: centered).
    public static func plusGlyphOffsetY(iOS27: Bool) -> CGFloat { iOS27 ? -1.0 / 3 : 0 }
    /// The send glyph: SF Symbol `arrow.up`, bold, medium scale: 13 by 16 pt
    /// of ink with a 2.33 pt stroke. The size is the best pixel fit to
    /// Messages' arrow in place (16.6 to 18 pt searched in 0.1 pt steps).
    public static let sendSymbolPointSize: CGFloat = 17.1

    /// The side inset as the keyboard rises (`keyboardProgress` 0 hidden,
    /// 1 docked), from `restInset` to `keyboardInset`.
    public static func sideInset(keyboardProgress: CGFloat, restInset: CGFloat = restSideInset, keyboardInset: CGFloat) -> CGFloat {
        let p = min(1, max(0, keyboardProgress))
        return restInset + (keyboardInset - restInset) * p
    }

    /// Frames of the row's parts.
    public struct Layout: Equatable, Sendable {
        /// The "+" circle, in the row's coordinates.
        public var plus: CGRect
        /// The field, in the row's coordinates.
        public var field: CGRect
        /// The send capsule, in the field's coordinates.
        public var send: CGRect
    }

    /// Lays out a row of `width` whose field ends at `fieldBottom`.
    /// - Parameters:
    ///   - fieldHeight: the field's current height (it grows upward).
    ///   - oneLineHeight: the field's one-line height; the "+" and the send
    ///     capsule center on that last line.
    ///   - sideInset: the current side inset (see `sideInset`).
    ///   - scale: the display scale. The "+" and the send capsule land on
    ///     whole pixels the way Messages' do.
    public static func layout(width: CGFloat, fieldBottom: CGFloat, fieldHeight: CGFloat, oneLineHeight: CGFloat, sideInset: CGFloat, scale: CGFloat) -> Layout {
        let lineMidY = fieldBottom - oneLineHeight / 2
        let plusY = pixelCeil(lineMidY - plusDiameter / 2, scale: scale)
        let plus = CGRect(x: sideInset, y: plusY, width: plusDiameter, height: plusDiameter)
        let fieldX = plus.maxX + plusToFieldGap
        let field = CGRect(x: fieldX, y: fieldBottom - fieldHeight, width: max(0, width - sideInset - fieldX), height: fieldHeight)
        let send = CGRect(
            x: field.width - sendTrailingInset - sendSize.width,
            y: pixelCeil(lineMidY - sendSize.height / 2, scale: scale) - field.minY,
            width: sendSize.width, height: sendSize.height
        )
        return Layout(plus: plus, field: field, send: send)
    }

    /// Rounds up to a whole pixel, as Messages places the "+" and the send
    /// capsule: a "+" centered on a 554.67 pt field lands at 555.0 (not
    /// 554.81), and the send capsule 6.33 pt into it (not 6.14).
    static func pixelCeil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return ((value * scale) - 1e-6).rounded(.up) / scale
    }

}
