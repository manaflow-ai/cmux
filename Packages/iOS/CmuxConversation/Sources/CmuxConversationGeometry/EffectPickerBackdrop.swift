import CoreGraphics

/// Messages' Send with effect backdrop. ChatKit's `CKEffectPickerStandardView`
/// layers a linear-light tint (`tint`) under a radius-64 Gaussian backdrop
/// rendered at half resolution, then a 50 % black overlay in dark mode and
/// 15 % white in light mode. UIKit's public materials blur far less, so the
/// picker blurs a small snapshot of the conversation with this recipe.
public struct EffectPickerBackdrop: Equatable, Sendable {
    /// An sRGB color in 0...255 channels with a 0...1 alpha.
    public struct RGBA: Equatable, Sendable {
        public let red: CGFloat
        public let green: CGFloat
        public let blue: CGFloat
        public let alpha: CGFloat

        public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    /// The overlay's white level (0 black, 1 white) and opacity.
    public let washWhite: CGFloat
    public let washAlpha: CGFloat

    public init(dark: Bool) {
        washWhite = dark ? 0 : 1
        washAlpha = dark ? 0.5 : 0.15
    }

    /// The Gaussian radius in points.
    public static let blurRadius: CGFloat = 64
    /// The blue-gray tint blended (linear light) under the blur.
    public static let tint = RGBA(red: 45, green: 66, blue: 95, alpha: 0.08)
    /// Snapshot pixels per point: a radius-64 blur keeps nothing finer.
    public static let renderScale: CGFloat = 0.25
    /// The blur radius in snapshot pixels.
    public static var pixelRadius: CGFloat { blurRadius * renderScale }

    /// The backdrop's 0...255 level over a blurred content level.
    public func level(overBlurred content: CGFloat) -> CGFloat {
        content * (1 - washAlpha) + washWhite * 255 * washAlpha
    }
}
