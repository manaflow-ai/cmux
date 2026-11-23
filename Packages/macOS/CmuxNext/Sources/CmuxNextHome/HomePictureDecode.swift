public import CoreGraphics
public import Foundation
import ImageIO

/// Decodes a Home picture's bytes (a Chief's avatar file) in full, on the caller's thread.
public nonisolated struct HomePictureDecode {
    public nonisolated init() {}
    /// The first frame of the picture `data` holds, decoded now.
    public static func firstFrame(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
