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

    /// Every pixel within a few levels of the first. A 64-pixel-wide copy answers for nearly every
    /// real picture at once (it differs somewhere). A copy that small can also lose all of a sparse
    /// page (a short chat: a few thin strokes of text on one colour), so a copy that looks solid
    /// is only believed once every pixel of the picture itself agrees.
    static func isSolid(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return false }
        let width = min(cg.width, 64)
        let height = max(1, Int((Double(cg.height) * Double(width) / Double(cg.width)).rounded()))
        var first: Pixel?
        let copy = CGRect(x: 0, y: 0, width: width, height: height)
        guard uniform(cg, drawnIn: copy, width: width, height: height, first: &first) == true else { return false }
        if width == cg.width, height == cg.height { return true }
        // The picture itself, a band of rows at a time (a whole page at 3x is 12 MB at once).
        let band = min(cg.height, 256)
        first = nil
        var row = 0
        while row < cg.height {
            let whole = CGRect(x: 0, y: -row, width: cg.width, height: cg.height)
            let rows = min(band, cg.height - row)
            guard uniform(cg, drawnIn: whole, width: cg.width, height: rows, first: &first) == true else { return false }
            row += rows
        }
        return true
    }

    private typealias Pixel = (r: Int, g: Int, b: Int, a: Int)

    /// `cg` drawn in `rect` of a `width` by `height` bitmap: whether every pixel is within a few
    /// levels of `first` (the bitmap's first pixel when nil, kept for the next band). Nil when
    /// the bitmap cannot be made.
    private static func uniform(_ cg: CGImage, drawnIn rect: CGRect, width: Int, height: Int, first: inout Pixel?) -> Bool? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(cg, in: rect)
            return true
        }
        guard drawn else { return nil }
        let one = first ?? (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
        first = one
        return bytes.withUnsafeBufferPointer { pixels in
            for i in Swift.stride(from: 0, to: pixels.count, by: 4) {
                if abs(Int(pixels[i]) - one.r) > 6 || abs(Int(pixels[i + 1]) - one.g) > 6 || abs(Int(pixels[i + 2]) - one.b) > 6
                    || abs(Int(pixels[i + 3]) - one.a) > 6 { return false }
            }
            return true
        }
    }
}
#endif
