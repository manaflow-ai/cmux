import AppKit
@testable import MessagesLabSidebar
import Testing

/// The Home list draws an emoji avatar (a Chief's 🫡) centered on its grey disc, at one share of
/// the disc on the big pinned tile and on the 40 pt row. The user's screenshot (2026-10-20)
/// showed a small emoji in a big disc on the tile and a bigger one on the row. 🫡's own art is
/// cut at its right on macOS 27 (26A428) whichever way it is drawn (CTLineDraw flipped or upright,
/// CTFontDrawGlyphs, NSAttributedString.draw: fleet probe 55c5613f7ca6776eb6562124, where 😀 drew
/// whole every way), so only an emoji drawn whole by the font proves the list does not cut it.
@MainActor
struct HomeSidebarEmojiAvatarTests {
    /// The ink of an avatar bitmap: the pixels inside the disc that differ from the disc's grey.
    struct Ink {
        var box: CGRect          // points, top-left origin
        var edgeColumns: (left: Int, right: Int)  // ink pixels in the outermost ink columns
        var heightPixels: Int
    }

    private func ink(_ spec: AvatarSpec, diameter d: CGFloat, scale: CGFloat = 2) throws -> Ink {
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let palette = SidebarPalette.resolve(appearance)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = SidebarRenderContext(metrics: SidebarMetrics(width: SidebarMetrics.preferredWidth), palette: palette,
                                       scale: scale, space: space, generation: 0, bellSecondary: nil, bellSelected: nil, now: Date())
        let image = try #require(SidebarAvatarCache().image(spec, diameter: d, ctx: ctx))
        let w = image.width, h = image.height
        let g = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        g.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = try #require(g.data).assumingMemoryBound(to: UInt8.self)
        // The disc's grey, read near the disc's top center (inside the disc, above any emoji;
        // the bitmap's first row in memory is its top).
        let top = (6 * w + w / 2) * 4
        let ref = (Int(px[top]), Int(px[top + 1]), Int(px[top + 2]))
        let r = CGFloat(w) / 2
        var minX = w, maxX = -1, minY = h, maxY = -1
        var columns = [Int](repeating: 0, count: w)
        for y in 0..<h {
            for x in 0..<w {
                let dx = CGFloat(x) + 0.5 - r, dy = CGFloat(y) + 0.5 - r
                guard dx * dx + dy * dy < (r - 2) * (r - 2) else { continue }
                let i = (y * w + x) * 4
                let diff = abs(Int(px[i]) - ref.0) + abs(Int(px[i + 1]) - ref.1) + abs(Int(px[i + 2]) - ref.2)
                guard diff > 60 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                columns[x] += 1
            }
        }
        try #require(maxX >= minX, "no ink drawn")
        let box = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                         width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return Ink(box: box, edgeColumns: (columns[minX], columns[maxX]), heightPixels: maxY - minY + 1)
    }

    /// The pinned tile's avatar bitmap (drawn at the largest pin size, then scaled) and the row's.
    @Test(arguments: [SidebarMetrics.pinMaxAvatar, SidebarMetrics.avatar], ["🫡", "😀"])
    func theEmojiIsCenteredAtItsShare(_ d: CGFloat, _ emoji: String) throws {
        let ink = try ink(.emoji(emoji), diameter: d)
        let note = "\(emoji) d \(d): ink \(ink.box), edge columns \(ink.edgeColumns), ink height \(ink.heightPixels) px"
        // Whole (😀 only, see above): a cut leaves a straight edge as tall as the face; a round edge's outermost column is short.
        if emoji == "😀" {
            #expect(ink.edgeColumns.left < ink.heightPixels / 3 && ink.edgeColumns.right < ink.heightPixels / 3, "cut: \(note)")
        }
        // Centered on the disc, both ways.
        #expect(abs(ink.box.midX - d / 2) <= d * 0.04, "off center: \(note)")
        #expect(abs(ink.box.midY - d / 2) <= d * 0.04, "off center: \(note)")
        // Fills its share of the disc and stays inside it.
        #expect(ink.box.width >= d * 0.5 && ink.box.width <= d * 0.72, "size: \(note)")
    }

    /// The tile and the row draw the emoji at one share of their disc.
    @Test func tileAndRowShareTheEmojiInset() throws {
        let tile = try ink(.emoji("🫡"), diameter: SidebarMetrics.pinMaxAvatar)
        let row = try ink(.emoji("🫡"), diameter: SidebarMetrics.avatar)
        let tileShare = max(tile.box.width, tile.box.height) / SidebarMetrics.pinMaxAvatar
        let rowShare = max(row.box.width, row.box.height) / SidebarMetrics.avatar
        #expect(abs(tileShare - rowShare) <= 0.04, "tile \(tileShare) vs row \(rowShare)")
    }
}
