public import CoreGraphics

/// The sizes of the one Sign In button (``SignInButton``) at one density.
///
/// Every place that tells a person to sign in shows this button (Lawrence, msg 3790: "everywhere we
/// say sign in, we need to have a button for signing in"). Its sizes come from the density tokens,
/// so it sits with the controls around it at every density: a control's height (`controlHeight`), the
/// density's spacing and its body text. Its corner is a control's (`Metrics.controlCornerRadius`, two
/// levels inside the one corner radius), which the caller passes.
///
/// ```swift
/// let metrics = SignInButtonMetrics(density: .compact, cornerRadius: Metrics.controlCornerRadius)
/// metrics.height // 24
/// ```
public nonisolated struct SignInButtonMetrics: Equatable, Sendable {
    /// The button's height: a control's height (24 pt at Compact, 30 at Comfortable).
    public var height: CGFloat
    /// The room on each side of the title.
    public var paddingX: CGFloat
    /// The fill's corner radius: a control's corner (`Metrics.controlCornerRadius`).
    public var cornerRadius: CGFloat
    /// The title's size in points: the density's body text.
    public var textSize: CGFloat

    /// The sizes at `density`, times `scale` (the interface scale; 1 keeps them).
    /// - Parameters:
    ///   - density: The density to read (``DensityTokens/active`` for the app's).
    ///   - cornerRadius: The fill's corner, already scaled: `Metrics.controlCornerRadius` in the app.
    ///   - scale: The interface scale, `Metrics.scale` in the app; 1 in tests.
    public init(density: DensityTokens, cornerRadius: CGFloat, scale: CGFloat = 1) {
        height = (density.resolve(compact: 24, comfortable: 30, token: "controlHeight") * scale).rounded()
        paddingX = (density.space(10) * scale).rounded()
        self.cornerRadius = cornerRadius
        textSize = density.textSize(compact: 12, comfortable: 13) * scale
    }

    /// Makes metrics from exact values.
    public init(height: CGFloat, paddingX: CGFloat, cornerRadius: CGFloat, textSize: CGFloat) {
        (self.height, self.paddingX, self.cornerRadius, self.textSize) = (height, paddingX, cornerRadius, textSize)
    }
}
