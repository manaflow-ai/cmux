import AppKit

/// Redraws browser snapshots into one owned packed-sRGB pixel buffer.
struct BrowserScreenshotPixelNormalizer {
    /// Normalizes an image into packed RGBA bytes.
    ///
    /// - Parameter image: Image to normalize.
    /// - Returns: Pixel data, dimensions, and row stride, or `nil` when the image is not drawable.
    func normalize(
        _ image: NSImage
    ) -> (data: Data, width: Int, height: Int, bytesPerRow: Int)? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0,
              height > 0,
              width <= Int.max / 4 else {
            return nil
        }
        let bytesPerRow = width * 4
        guard height <= Int.max / bytesPerRow,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        var data = Data(count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let didDraw = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard didDraw else {
            return nil
        }
        return (data, width, height, bytesPerRow)
    }
}
