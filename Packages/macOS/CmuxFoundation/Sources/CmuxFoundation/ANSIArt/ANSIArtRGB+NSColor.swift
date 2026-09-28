public import AppKit

extension ANSIArtRGB {
    /// Creates a color from an AppKit color, converted to sRGB. A color with
    /// no sRGB representation (a pattern, for example) becomes black.
    ///
    /// - Parameter color: The AppKit color.
    public init(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            self.init(0, 0, 0)
            return
        }
        self.init(Self.channel(srgb.redComponent), Self.channel(srgb.greenComponent), Self.channel(srgb.blueComponent))
    }

    private static func channel(_ value: CGFloat) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded())
    }
}
