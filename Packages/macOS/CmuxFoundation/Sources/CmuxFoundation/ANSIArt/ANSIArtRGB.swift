/// An opaque 24-bit sRGB color used by ANSI art styling.
public struct ANSIArtRGB: Hashable, Sendable {
    /// The red channel, 0...255.
    public var red: UInt8
    /// The green channel, 0...255.
    public var green: UInt8
    /// The blue channel, 0...255.
    public var blue: UInt8

    /// Creates a color from its three 8-bit channels.
    ///
    /// - Parameters:
    ///   - red: The red channel.
    ///   - green: The green channel.
    ///   - blue: The blue channel.
    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}
