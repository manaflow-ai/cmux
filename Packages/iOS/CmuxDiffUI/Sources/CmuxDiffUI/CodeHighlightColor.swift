/// A platform-neutral syntax color safe to cross concurrency boundaries.
public struct CodeHighlightColor: Sendable, Equatable {
    /// Red component in the range zero through one.
    public let red: Double
    /// Green component in the range zero through one.
    public let green: Double
    /// Blue component in the range zero through one.
    public let blue: Double
    /// Alpha component in the range zero through one.
    public let alpha: Double

    /// Creates a platform-neutral RGBA color.
    /// - Parameters:
    ///   - red: Red component.
    ///   - green: Green component.
    ///   - blue: Blue component.
    ///   - alpha: Alpha component.
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
