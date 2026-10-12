import CoreGraphics

/// A blurred veil over the transcript built from public UIKit pieces: a
/// system material held part way by a paused animator, under a solid wash.
public struct ConversationVeilBlur: Equatable, Sendable {
    /// How far the paused animator holds the ultra-thin system material.
    public let materialShare: CGFloat
    /// The wash's white level (0 black, 1 white) and opacity.
    public let washWhite: CGFloat
    public let washAlpha: CGFloat

    public init(materialShare: CGFloat, washWhite: CGFloat, washAlpha: CGFloat) {
        self.materialShare = materialShare
        self.washWhite = washWhite
        self.washAlpha = washAlpha
    }
}

extension ConversationVeilBlur {
    /// The details page's backdrop. Messages blurs the transcript with a
    /// pure radius-16 Gaussian under a 60 % white (dark: black) veil. The
    /// ultra-thin material at this share blurs about as far; its own lift
    /// (and slight saturation) stands in for part of the veil, so the wash
    /// is lighter. Fitted in iOS 26.5 and 27.0 against the pure blur over
    /// black, white, gray, blue and green: RMS error 1.5 (light) and 3.4
    /// (dark) levels, from 9.9 and 16.3 with the light/dark styles.
    public static func details(dark: Bool) -> ConversationVeilBlur {
        dark
            ? ConversationVeilBlur(materialShare: 0.55, washWhite: 0, washAlpha: 0.55)
            : ConversationVeilBlur(materialShare: 0.65, washWhite: 1, washAlpha: 0.49)
    }
}
