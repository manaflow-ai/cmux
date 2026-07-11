/// Pixel dimensions of the Android emulator's primary display.
public struct AndroidEmulatorDisplaySize: Sendable, Equatable {
    /// Display width in pixels.
    public let width: Int
    /// Display height in pixels.
    public let height: Int

    /// Creates a pixel size.
    ///
    /// - Parameters:
    ///   - width: Display width in pixels.
    ///   - height: Display height in pixels.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}
