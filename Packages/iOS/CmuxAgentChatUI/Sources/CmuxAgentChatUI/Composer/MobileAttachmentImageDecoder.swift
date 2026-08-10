#if os(iOS)
import Foundation
import ImageIO

struct MobileAttachmentImageDecoder: Sendable {
    static let fullPreviewMaxPixelSize = 4096

    func decode(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return decode(data: data, maxPixelSize: maxPixelSize)
    }

    func decode(data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
#endif
