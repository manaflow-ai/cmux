public import AppKit

/// One appearance's colors for a ``FloatingGlassStyle``: a neutral gray veil and the rim's
/// top-to-bottom gradient. Gray only: never a theme hue or an accent.
public nonisolated struct FloatingGlassLook: Sendable, Equatable {
    /// A gray level and opacity.
    public nonisolated struct Gray: Sendable, Equatable {
        /// 0 is black, 1 is white.
        public var white: Double
        /// Opacity, 0...1.
        public var alpha: Double

        /// - Parameters:
        ///   - white: The gray level (0 black, 1 white).
        ///   - alpha: The opacity.
        public init(white: Double, alpha: Double) {
            self.white = white
            self.alpha = alpha
        }

        /// The color in sRGB.
        public var nsColor: NSColor { NSColor(srgbRed: white, green: white, blue: white, alpha: alpha) }
    }

    /// The tint laid over the glass (or the blur before macOS 26).
    public var veil: Gray
    /// The rim at the top edge.
    public var rimTop: Gray
    /// The rim at the bottom edge.
    public var rimBottom: Gray

    /// - Parameters:
    ///   - veil: The tint over the glass.
    ///   - rimTop: The rim at the top.
    ///   - rimBottom: The rim at the bottom.
    public init(veil: Gray, rimTop: Gray, rimBottom: Gray) {
        self.veil = veil
        self.rimTop = rimTop
        self.rimBottom = rimBottom
    }
}
