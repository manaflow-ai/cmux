public import CoreGraphics

/// A fully resolved, `Sendable` description of one terminal-pane ring overlay
/// stroke (the notification ring or a flash style).
///
/// The app target owns the attention palette and ring metrics (both resolve to
/// `NSColor`/app constants), so it computes these primitive values once and
/// hands them to the overlay container. The view layer applies them verbatim
/// without importing the app-target presentation types, which keeps the
/// terminal-surface view package free of any reach-up into app code.
public struct TerminalPaneRingPresentation: Sendable, Equatable {
    /// Stroke/glow color, as straight sRGB components in `0...1`.
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    /// CALayer shadow opacity used for the glow.
    public var glowOpacity: Double
    /// CALayer shadow radius used for the glow.
    public var glowRadius: CGFloat
    /// Stroke line width of the ring.
    public var lineWidth: CGFloat
    /// Inset of the ring path from the overlay bounds.
    public var inset: CGFloat
    /// Corner radius of the ring path.
    public var cornerRadius: CGFloat

    /// Creates a resolved ring presentation from primitive values.
    public init(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double,
        glowOpacity: Double,
        glowRadius: CGFloat,
        lineWidth: CGFloat,
        inset: CGFloat,
        cornerRadius: CGFloat
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.glowOpacity = glowOpacity
        self.glowRadius = glowRadius
        self.lineWidth = lineWidth
        self.inset = inset
        self.cornerRadius = cornerRadius
    }

    /// A fully-transparent, zero-metric presentation used as an initial value
    /// before the app target configures the real palette.
    public static let zero = TerminalPaneRingPresentation(
        red: 0,
        green: 0,
        blue: 0,
        alpha: 0,
        glowOpacity: 0,
        glowRadius: 0,
        lineWidth: 0,
        inset: 0,
        cornerRadius: 0
    )
}
