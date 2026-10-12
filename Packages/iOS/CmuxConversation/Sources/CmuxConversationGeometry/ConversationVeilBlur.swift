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
    /// The details page's backdrop.
    public static func details(dark: Bool) -> ConversationVeilBlur {
        ConversationVeilBlur(materialShare: 16.0 / 30.0, washWhite: dark ? 0 : 1, washAlpha: 0.6)
    }
}
