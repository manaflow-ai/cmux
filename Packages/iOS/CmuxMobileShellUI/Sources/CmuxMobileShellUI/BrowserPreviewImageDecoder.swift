#if canImport(UIKit)
import CoreGraphics
import Foundation
import ImageIO

/// Downsamples browser frames away from the main actor before SwiftUI stores them.
struct BrowserPreviewImageDecoder {
    func decode(_ data: Data, maxPixelDimension: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelDimension),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}
#endif
