/// An immutable sRGB color used by a syntax palette.
public struct FilePreviewSyntaxColor: Equatable, Sendable {
    /// Red component in `0...1`.
    public let red: Double
    /// Green component in `0...1`.
    public let green: Double
    /// Blue component in `0...1`.
    public let blue: Double
    /// Alpha component in `0...1`.
    public let alpha: Double

    /// Creates an sRGB syntax color.
    ///
    /// - Parameters:
    ///   - red: Red component.
    ///   - green: Green component.
    ///   - blue: Blue component.
    ///   - alpha: Alpha component, defaulting to fully opaque.
    public init(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double = 1
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
