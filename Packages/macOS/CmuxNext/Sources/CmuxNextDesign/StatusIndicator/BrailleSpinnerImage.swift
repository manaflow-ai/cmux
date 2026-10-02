import AppKit
import CoreText

/// The terminal braille spinner (`StatusIndicatorStyle.braille`): the frames
/// CLI tools print while they work, rendered once per pixel size and font
/// as alpha masks. The layer tints a mask and steps its `contents` through
/// them in the render server (no text layout per frame, no timer).
@MainActor
enum BrailleSpinnerImage {
    /// The frames in order. Static (Reduce Motion, loops off, occluded), the
    /// indicator keeps the first.
    static let frames: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private struct Key: Hashable {
        var pixels: Int
        var scale: Int
        var family: String?
    }

    private static var cache: [Key: [CGImage]] = [:]

    /// The frames for a `side`-point square at `scale`, in `family` (the
    /// terminal font; nil or unknown falls back to the system monospaced
    /// font, and Core Text falls back per glyph when a font has no braille).
    /// Empty when nothing could be drawn.
    static func images(side: CGFloat, scale: CGFloat, family: String?) -> [CGImage] {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0 else { return [] }
        let key = Key(pixels: pixels, scale: Int(scale.rounded()), family: family)
        if let cached = cache[key] { return cached }
        let images = render(pixels: pixels, family: family)
        guard images.count == frames.count else { return [] }
        if cache.count > 16 { cache.removeAll() }
        cache[key] = images
        return images
    }

    /// The font the frames use at `size` points.
    static func font(family: String?, size: CGFloat) -> NSFont {
        if let family, let font = NSFont(name: family, size: size) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func render(pixels: Int, family: String?) -> [CGImage] {
        // Size and place every frame from the full cell (⣿), so the dots
        // never shift between frames and the cell fills the square's height.
        let reference: CGFloat = 100
        let full = line("⣿", font: font(family: family, size: reference))
        let cell = CTLineGetImageBounds(full, nil)
        guard cell.width > 0, cell.height > 0 else { return [] }
        let fit = CGFloat(pixels) / max(cell.width, cell.height)
        let font = font(family: family, size: reference * fit)
        let bounds = CTLineGetImageBounds(line("⣿", font: font), nil)
        let origin = CGPoint(x: (CGFloat(pixels) - bounds.width) / 2 - bounds.minX,
                             y: (CGFloat(pixels) - bounds.height) / 2 - bounds.minY)
        return frames.compactMap { frame in
            guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return nil }
            context.setShouldAntialias(true)
            context.textPosition = origin
            CTLineDraw(line(String(frame), font: font), context)
            return context.makeImage()
        }
    }

    private static func line(_ text: String, font: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
    }
}
