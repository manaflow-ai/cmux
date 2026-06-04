/// An RGB color read from the libghostty config (0–255 channels).
public struct GhosttyConfigColor: Sendable, Equatable {
    /// Red channel (0–255).
    public let red: UInt8
    /// Green channel (0–255).
    public let green: UInt8
    /// Blue channel (0–255).
    public let blue: UInt8

    /// Creates a color.
    /// - Parameters:
    ///   - red: Red channel (0–255).
    ///   - green: Green channel (0–255).
    ///   - blue: Blue channel (0–255).
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}
