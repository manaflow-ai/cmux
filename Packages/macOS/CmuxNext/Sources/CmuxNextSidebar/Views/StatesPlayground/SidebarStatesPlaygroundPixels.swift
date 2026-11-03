import CoreGraphics

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): a shot's pixels in RGBA order, to measure a mark's ink:
/// the box of the pixels that differ from the row behind the mark.
struct SidebarStatesPlaygroundPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    /// Draws `image` into an sRGB RGBA buffer; nil when no context could be made.
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        (self.width, self.height, self.bytes) = (width, height, bytes)
    }

    /// Channel `channel` (RGBA) of the pixel at column `x`, row `y` (row 0 is the image's top).
    private func value(_ x: Int, _ y: Int, _ channel: Int) -> Int { Int(bytes[(y * width + x) * 4 + channel]) }

    /// The box, in pixels (top-left origin), of the pixels inside `box` that differ from the backdrop: the median of
    /// `box`'s own edge pixels (a mark sits inside its frame, so its edge is mostly the row behind it; a ring outside
    /// it could fall on another fill, as a group header's band). Nil when none differ by more than `threshold`.
    func inkBox(in box: CGRect, threshold: Int = 40) -> CGRect? {
        let inner = box.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard inner.width >= 2, inner.height >= 2 else { return nil }
        let (x0, y0, x1, y1) = (Int(inner.minX), Int(inner.minY), Int(inner.maxX) - 1, Int(inner.maxY) - 1)
        var ring: [(Int, Int)] = []
        for x in x0...x1 { ring += [(x, y0), (x, y1)] }
        for y in y0...y1 { ring += [(x0, y), (x1, y)] }
        let backdrop = (0..<4).map { channel in ring.map { value($0.0, $0.1, channel) }.sorted()[ring.count / 2] }
        var found: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
        for y in Int(inner.minY)..<Int(inner.maxY) {
            for x in Int(inner.minX)..<Int(inner.maxX) {
                guard (0..<4).contains(where: { abs(value(x, y, $0) - backdrop[$0]) > threshold }) else { continue }
                found = found.map { (min($0.minX, x), min($0.minY, y), max($0.maxX, x), max($0.maxY, y)) } ?? (x, y, x, y)
            }
        }
        return found.map { CGRect(x: $0.minX, y: $0.minY, width: $0.maxX - $0.minX + 1, height: $0.maxY - $0.minY + 1) }
    }
}
