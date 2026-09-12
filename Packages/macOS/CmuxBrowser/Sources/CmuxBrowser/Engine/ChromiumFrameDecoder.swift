import CoreGraphics
public import Foundation
import ImageIO

/// Decodes screencast PNGs on its own executor, keeping decompression off the
/// main actor. Callers consume a newest-frame stream and await one decode at a time.
public actor ChromiumFrameDecoder {
    /// Creates a serial decoder for one pane.
    public init() {}

    /// Returns a fully decoded frame, rejecting malformed or oversized images.
    /// - Parameter data: PNG bytes from the bounded screencast stream.
    /// - Returns: A decoded image, or nil when decoding fails.
    public func decode(_ data: Data) -> ChromiumDecodedFrame? {
        guard data.count <= 24 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 32 * 1024 * 1024,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return ChromiumDecodedFrame(image: image)
    }
}
