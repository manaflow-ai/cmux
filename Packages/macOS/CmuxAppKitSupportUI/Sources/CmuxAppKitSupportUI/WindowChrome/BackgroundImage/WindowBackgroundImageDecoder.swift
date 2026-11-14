public import Foundation
import ImageIO

/// Decodes a window background image file into a bitmap no larger than the
/// window needs.
///
/// A photo from a camera can be 50 megapixels. Decoding it at full size would
/// hold hundreds of megabytes per window, so the decoder downsamples to
/// ``maxPixelSize`` on its longest side and applies the EXIF orientation. Any
/// format ImageIO reads works (PNG, JPEG, HEIC, TIFF, GIF's first frame).
///
/// Decoding is synchronous and reads the disk; call it off the main actor.
///
/// ```swift
/// let decoder = WindowBackgroundImageDecoder()
/// let image = await Task.detached { decoder.decode(contentsOf: url) }.value
/// ```
public struct WindowBackgroundImageDecoder: Sendable {
    /// The default longest side, in pixels. It covers a 6K display at full
    /// resolution, so the image stays sharp on any Mac screen.
    public static let defaultMaxPixelSize = 6144

    /// The longest side, in pixels, of a decoded image. Smaller images are not
    /// enlarged.
    public let maxPixelSize: Int

    /// Creates a decoder.
    ///
    /// - Parameter maxPixelSize: The longest side, in pixels, of a decoded
    ///   image. Values below 1 are raised to 1.
    public init(maxPixelSize: Int = WindowBackgroundImageDecoder.defaultMaxPixelSize) {
        self.maxPixelSize = max(1, maxPixelSize)
    }

    /// Decodes the image at `url`.
    ///
    /// - Parameter url: The image file.
    /// - Returns: The decoded image, or `nil` when the file is missing, is
    ///   not an image ImageIO can read, or cannot be decoded.
    public func decode(contentsOf url: URL) -> WindowBackgroundImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return WindowBackgroundImage(cgImage: image)
    }
}
