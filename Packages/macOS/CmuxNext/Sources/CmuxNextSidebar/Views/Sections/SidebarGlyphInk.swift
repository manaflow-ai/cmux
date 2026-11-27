import AppKit

/// The drawn extent ("ink") of a glyph image: the box of its opaque pixels,
/// in the image's points from its top-left corner. Registry icons leave
/// different margins inside their square (a circle avatar, a gear's teeth),
/// so two glyphs at one image size look different sizes. Icon-only sidebar
/// items size and center the ink, not the image box
/// (SIDEBAR-FOOTER-AND-SPACE-MENU, Lawrence 2026-10-06: the footer's avatar
/// and gear must read as one size on one center line).
///
/// Measured once per glyph and size and cached: a layout pass asks for
/// every icon item.
@MainActor final class SidebarGlyphInk {
    static let shared = SidebarGlyphInk()

    /// Measuring resolution, pixels per point: a quarter-point grid.
    private let scale: CGFloat = 4
    /// Alpha (of 255) a pixel needs to count as ink, so the antialiased
    /// fringe does not grow the box.
    private let threshold: UInt8 = 64
    private var boxes: [Key: CGRect] = [:]

    private struct Key: Hashable {
        var glyph: String
        var side: CGFloat
    }

    /// The ink box of `image` (top-left origin, points). `glyph` names the
    /// drawing (its icon, brand or symbol) for the cache. Nil when nothing
    /// draws.
    func box(of image: NSImage, glyph: String) -> CGRect? {
        let key = Key(glyph: glyph, side: image.size.width)
        if let cached = boxes[key] { return cached.isNull ? nil : cached }
        let box = measure(image)
        if boxes.count > 256 { boxes.removeAll() }
        boxes[key] = box ?? .null
        return box
    }

    /// Draws `image` into an RGBA bitmap and scans its alpha. Bitmap row 0
    /// is the image's top, so rows are already top-left coordinates.
    private func measure(_ image: NSImage) -> CGRect? {
        let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
