public import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers

extension HomeChiefAvatars {
    /// The longest side of the picture a web page gets: the Messages page's 36 pt header tile and
    /// its first-run hero at 2x, with room.
    nonisolated static let pagePictureSide = 256

    /// The first frame of the picture `data` holds, decoded now (call it off the main actor).
    public nonisolated static func firstFrame(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// A Chief's header picture (``headerAvatar(chief:fallback:)``'s bytes) for a web page: its
    /// first frame, scaled to fit ``pagePictureSide``, as a PNG data URL; nil when it does not decode.
    /// Decoded off the main actor.
    @concurrent
    public nonisolated static func pagePicture(_ data: Data) async -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pagePictureSide,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/png;base64," + (out as Data).base64EncodedString()
    }
}
