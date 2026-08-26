import Foundation

/// Metadata returned after a mounted sidebar has been encoded as PNG.
public struct CustomSidebarRenderArtifact: Sendable {
    /// The path where the PNG was written.
    public let outputURL: URL
    /// The encoded artifact width in pixels.
    public let width: Int
    /// The encoded artifact height in pixels.
    public let height: Int
    /// Number of bitmap pixels whose alpha exceeded the visibility threshold.
    public let visiblePixelCount: Int
    /// Number of bytes in the encoded PNG.
    public let byteCount: Int

    /// Creates artifact metadata.
    ///
    /// - Parameters:
    ///   - outputURL: The path where the PNG was written.
    ///   - width: The encoded width in pixels.
    ///   - height: The encoded height in pixels.
    ///   - visiblePixelCount: Count of non-transparent pixels.
    ///   - byteCount: Number of encoded PNG bytes.
    public init(
        outputURL: URL,
        width: Int,
        height: Int,
        visiblePixelCount: Int,
        byteCount: Int
    ) {
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.visiblePixelCount = visiblePixelCount
        self.byteCount = byteCount
    }
}
