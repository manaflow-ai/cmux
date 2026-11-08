import AppKit

/// Redraws one bounded browser-snapshot region into packed sRGB pixels.
struct BrowserScreenshotPixelNormalizer {
    private let maximumPixelCount = 1_048_576

    /// Normalizes a top-left-origin snapshot rectangle into packed RGBA bytes.
    ///
    /// - Parameters:
    ///   - image: Source browser snapshot.
    ///   - topLeftRect: Integral source-pixel rectangle in top-left coordinates.
    /// - Returns: Packed pixel data, or `nil` when the region is invalid, too
    ///   large, or not drawable.
    func normalize(
        _ image: CGImage,
        topLeftRect: NSRect
    ) -> BrowserScreenshotNormalizedPixelRegion? {
        guard topLeftRect.minX.isFinite,
              topLeftRect.minY.isFinite,
              topLeftRect.maxX.isFinite,
              topLeftRect.maxY.isFinite else {
            return nil
        }
        let minX = topLeftRect.minX
        let minY = topLeftRect.minY
        let maxX = topLeftRect.maxX
        let maxY = topLeftRect.maxY
        guard minX == minX.rounded(.down),
              minY == minY.rounded(.down),
              maxX == maxX.rounded(.down),
              maxY == maxY.rounded(.down),
              minX >= 0,
              minY >= 0,
              maxX <= CGFloat(image.width),
              maxY <= CGFloat(image.height) else {
            return nil
        }
        let rect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        let width = Int(rect.width)
        let height = Int(rect.height)
        guard width > 0,
              height > 0,
              width <= Int.max / height,
              width * height <= maximumPixelCount,
              width <= Int.max / 4 else {
            return nil
        }
        let bytesPerRow = width * 4
        guard height <= Int.max / bytesPerRow,
              let cropped = image.cropping(to: rect),
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
            // `CGImage.cropping(to:)` and a bitmap-context draw preserve the
            // provider's top-to-bottom scanline order in the destination bytes.
            context.draw(
                cropped,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard didDraw else { return nil }
        return BrowserScreenshotNormalizedPixelRegion(
            data: data,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
}
