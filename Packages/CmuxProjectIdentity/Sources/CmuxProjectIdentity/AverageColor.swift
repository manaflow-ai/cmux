import CoreGraphics
import Foundation

/// Computes the average color of an image by downsampling it to a single pixel.
struct AverageColor {
    /// Returns the average color of `image` as a `#RRGGBB` hex string, or `nil`
    /// if a drawing context could not be created.
    func hexString(of image: CGImage) -> String? {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }
}
