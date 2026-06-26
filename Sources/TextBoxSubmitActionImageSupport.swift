import AppKit
import Foundation

enum TextBoxSubmitActionImageSupport {
    static let iconSize: CGFloat = 16
    static let maximumCachedImageCount = 32

    private static let maximumImageBytes = 2 * 1024 * 1024

    private static var nsIconSize: NSSize {
        NSSize(width: iconSize, height: iconSize)
    }

    static func imageData(atPath path: String) -> Data? {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumImageBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func fixedSizeImage(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = nsIconSize
        return copy
    }
}
