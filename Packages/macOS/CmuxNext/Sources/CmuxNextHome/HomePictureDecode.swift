import CoreGraphics
import Foundation
import ImageIO

/// Decodes a Home picture's bytes (a Chief's avatar file) in full, on the caller's thread.
public nonisolated enum HomePictureDecode {
    /// The first frame of the picture `data` holds, decoded now.
    public static func firstFrame(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
