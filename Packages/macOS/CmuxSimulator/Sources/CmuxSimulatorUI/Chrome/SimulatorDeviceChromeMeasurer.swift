import CoreGraphics
import Foundation
import ImageIO

struct SimulatorDeviceChromeMeasurer: Sendable {
    /// Measures the center-connected opaque black opening in DeviceKit's
    /// composite artwork, matching serve-sim's iPhone and iPad geometry.
    func screenOpening(at url: URL) -> SimulatorDeviceChromeOpening? {
        guard let raster = simulatorDeviceChromeRaster(at: url),
              raster.width > 0,
              raster.height > 0 else { return nil }
        let centerX = raster.width / 2
        let centerY = raster.height / 2

        func isDark(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < raster.width, y < raster.height else { return false }
            return raster.bytes.withUnsafeBytes { bytes in
                let pixel = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    + (y * raster.bytesPerRow) + (x * 4)
                return pixel[3] > 200 && pixel[0] < 30 && pixel[1] < 30 && pixel[2] < 30
            }
        }

        guard isDark(centerX, centerY) else { return nil }
        var minimumX = centerX
        while minimumX > 0, isDark(minimumX - 1, centerY) { minimumX -= 1 }
        var maximumX = centerX
        while maximumX < raster.width - 1, isDark(maximumX + 1, centerY) { maximumX += 1 }
        var minimumY = centerY
        while minimumY > 0, isDark(centerX, minimumY - 1) { minimumY -= 1 }
        var maximumY = centerY
        while maximumY < raster.height - 1, isDark(centerX, maximumY + 1) { maximumY += 1 }

        let verticalSpan = maximumY - minimumY
        guard verticalSpan > 0 else { return nil }
        func cornerInset(x: Int, fromMinimumY: Bool) -> Int {
            var inset = 0
            while inset < verticalSpan,
                  !isDark(x, fromMinimumY ? minimumY + inset : maximumY - inset) {
                inset += 1
            }
            return inset
        }
        let radiusSamples = [
            cornerInset(x: minimumX, fromMinimumY: true),
            cornerInset(x: maximumX, fromMinimumY: true),
            cornerInset(x: minimumX, fromMinimumY: false),
            cornerInset(x: maximumX, fromMinimumY: false),
        ]
        let radiusPixels = Double(radiusSamples.reduce(0, +)) / 4
        return SimulatorDeviceChromeOpening(
            width: Double(maximumX - minimumX + 1) * raster.pointWidth / Double(raster.width),
            radius: radiusPixels * raster.pointHeight / Double(raster.height)
        )
    }
}

private func simulatorDeviceChromeRaster(at url: URL) -> SimulatorDeviceChromeRaster? {
    if let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) {
        let crop = page.getBoxRect(.cropBox)
        let bounds = crop.width > 0 && crop.height > 0 ? crop : page.getBoxRect(.mediaBox)
        return makeSimulatorDeviceChromeRaster(pointSize: bounds.size, pixelScale: 1) { context in
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.drawPDFPage(page)
        }
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let size = CGSize(width: image.width, height: image.height)
    if let raster = simulatorDeviceChromeRaster(image: image, pointSize: size) { return raster }
    return makeSimulatorDeviceChromeRaster(pointSize: size, pixelScale: 1) { context in
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }
}

private func makeSimulatorDeviceChromeRaster(
    pointSize: CGSize,
    pixelScale: CGFloat,
    draw: (CGContext) -> Void
) -> SimulatorDeviceChromeRaster? {
    let width = Int((pointSize.width * pixelScale).rounded(.up))
    let height = Int((pointSize.height * pixelScale).rounded(.up))
    guard width > 0, height > 0 else { return nil }
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
    ) else { return nil }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    let scaleX = CGFloat(width) / pointSize.width
    let scaleY = CGFloat(height) / pointSize.height
    if abs(scaleX - 1) > 0.000_001 || abs(scaleY - 1) > 0.000_001 {
        context.scaleBy(x: scaleX, y: scaleY)
    }
    draw(context)
    guard let image = context.makeImage() else { return nil }
    return simulatorDeviceChromeRasterThroughPNG(image: image, pointSize: pointSize)
        ?? simulatorDeviceChromeRaster(image: image, pointSize: pointSize)
}

/// DeviceKit's web implementation measures Apple's PDF after converting it
/// to PNG. The PNG color profile changes a few antialiased edge samples, so
/// preserve that normalization here to produce the same opening radius.
private func simulatorDeviceChromeRasterThroughPNG(
    image: CGImage,
    pointSize: CGSize
) -> SimulatorDeviceChromeRaster? {
    let encoded = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        encoded,
        "public.png" as CFString,
        1,
        nil
    ) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination),
          let source = CGImageSourceCreateWithData(encoded, nil),
          let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return simulatorDeviceChromeRaster(image: decoded, pointSize: pointSize)
}

private func simulatorDeviceChromeRaster(
    image: CGImage,
    pointSize: CGSize
) -> SimulatorDeviceChromeRaster? {
    let alpha = image.alphaInfo
    let order = image.bitmapInfo.intersection(.byteOrderMask)
    guard image.bitsPerComponent == 8,
          image.bitsPerPixel == 32,
          alpha == .last || alpha == .premultipliedLast,
          order.isEmpty || order == .byteOrder32Big,
          let providerBytes = image.dataProvider?.data else { return nil }
    return SimulatorDeviceChromeRaster(
        width: image.width,
        height: image.height,
        pointWidth: pointSize.width,
        pointHeight: pointSize.height,
        bytesPerRow: image.bytesPerRow,
        bytes: providerBytes as Data
    )
}
