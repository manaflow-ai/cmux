#if os(iOS)
import UIKit

/// Whether a card picture is a placeholder rather than a picture of the tab: the cannot-draw mark
/// (`CannotDrawMark`), or one solid colour (a capture of a surface that had drawn nothing yet, the
/// black cards of Leo's 2026-11-24 grid). A gated picture is never shown or saved; the card keeps
/// its last real picture, its text, or nothing.
enum CardPictureGate {
    static func isPlaceholder(_ image: UIImage) -> Bool {
        CannotDrawMark.isIn(image) || isSolid(image)
    }

    /// Every pixel within a few levels of the first, read on a 64-pixel-wide copy. Text, a page,
    /// a frame of any app all differ by far more somewhere.
    static func isSolid(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return false }
        let width = min(cg.width, 64)
        let height = max(1, Int((Double(cg.height) * Double(width) / Double(cg.width)).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        let r0 = Int(bytes[0]), g0 = Int(bytes[1]), b0 = Int(bytes[2]), a0 = Int(bytes[3])
        for i in Swift.stride(from: 0, to: bytes.count, by: 4) {
            if abs(Int(bytes[i]) - r0) > 6 || abs(Int(bytes[i + 1]) - g0) > 6 || abs(Int(bytes[i + 2]) - b0) > 6
                || abs(Int(bytes[i + 3]) - a0) > 6 { return false }
        }
        return true
    }
}
#endif
