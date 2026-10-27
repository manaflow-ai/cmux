#if canImport(ImageIO)
public import Foundation
import ImageIO
import UniformTypeIdentifiers

// ImageIO is Apple's: the Linux tier has no image codecs, and only the macOS App makes profile icons.
extension SourceProfileLook {
    /// The picture as a PNG at most `side` pixels on its longest side and
    /// `maxBytes` long (an image icon); nil when there is none or it is not an image.
    public func avatarPNG(side: Int = 256, maxBytes: Int = 256 * 1024) -> Data? {
        guard let avatar, let source = CGImageSourceCreateWithURL(avatar as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), png.length <= maxBytes else { return nil }
        return png as Data
    }
}
#endif
