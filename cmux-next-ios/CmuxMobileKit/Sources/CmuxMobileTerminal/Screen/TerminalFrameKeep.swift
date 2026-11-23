#if os(iOS)
import CoreGraphics
import UIKit

/// The one gate a terminal page's frame passes before it may replace a tab's
/// cached frame (in memory or on disk). Leo, 2026-11-12, on LTE: "wack
/// reconnection state / just show the cache".
///
/// A frame is kept only when the page drew the Mac's output while attached
/// (`TerminalModel.drewLiveOutput`) and the frame is not blank. A surface that
/// never attached (a tab cooled or closed before its first attach, a relaunch
/// still reconnecting) is an empty page: saving it wrote a blank page over the
/// good cached frame, and the next launch showed nothing.
public enum TerminalFrameKeep {
    /// `image`, if it may replace the cached frame; nil if the caller keeps
    /// the cached frame it has.
    public static func kept(_ image: UIImage?, drewLiveOutput: Bool) -> UIImage? {
        guard drewLiveOutput, let image, !isBlank(image) else { return nil }
        return image
    }

    /// Every pixel is one color (within `tolerance` per channel): the page
    /// background with no rows drawn, or an image with no pixels at all.
    /// Checked on a copy at most `sampleWidth` wide, averaged down so one
    /// glyph's strokes still move its block off the background.
    public static func isBlank(_ image: UIImage, tolerance: Int = 6, sampleWidth: Int = 128) -> Bool {
        guard let cg = image.cgImage ?? render(image) else { return true }
        guard cg.width > 0, cg.height > 0 else { return true }
        let width = min(cg.width, sampleWidth)
        let height = max(1, Int((Double(cg.height) * Double(width) / Double(cg.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }
        let first = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]), Int(pixels[3]))
        var index = 4
        while index < pixels.count {
            if abs(Int(pixels[index]) - first.0) > tolerance || abs(Int(pixels[index + 1]) - first.1) > tolerance
                || abs(Int(pixels[index + 2]) - first.2) > tolerance || abs(Int(pixels[index + 3]) - first.3) > tolerance {
                return false
            }
            index += 4
        }
        return true
    }

    /// An image with no CGImage backing (a CIImage one): drawn once to get one.
    private static func render(_ image: UIImage) -> CGImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
    }
}
#endif
