import AppKit
import CmuxNextIcons
import Testing

/// REOPEN-F7 part A2 (whole stall stacks after a reopen, cmux18 job cea96828): the first window's display pass
/// rasterized every chrome glyph one view at a time (`NSImage CGImageForProposedRect`, `NSCGImageSnapshotRep`,
/// `CGBitmapAllocateData`), because `NSImage.icon` made a new drawing-handler image per call and AppKit caches a
/// raster per image instance. Chrome's model: one shared image cache. N views that show the same glyph at the same
/// size and scale share one bitmap: one rasterization per key.
@MainActor
@Suite struct IconRasterSharingTests {
    /// What a layer-backed image view asks the image for at `scale` (AppKit's `CGImageForProposedRect`).
    private static func bitmap(_ image: NSImage, side: CGFloat, scale: CGFloat) -> CGImage? {
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
    }

    @Test(arguments: [CGFloat(1), 2])
    func identicalPackGlyphsShareOneBitmapPerKey(scale: CGFloat) throws {
        let images = (0..<8).map { _ in NSImage.icon(.search, size: 14) }
        let bitmaps = try images.map { try #require(Self.bitmap($0, side: 14, scale: scale)) }
        #expect(Set(bitmaps.map(ObjectIdentifier.init)).count == 1, "8 identical glyphs rasterized \(Set(bitmaps.map(ObjectIdentifier.init)).count) times at \(scale)x")
        // The images' own representations are the shared bitmaps (not drawing handlers drawn per image).
        let reps = images.map { $0.representations.compactMap { ($0 as? NSBitmapImageRep)?.cgImage }.first { $0.width == Int(14 * scale) } }
        #expect(reps.allSatisfy { $0 != nil } && Set(reps.compactMap { $0.map(ObjectIdentifier.init) }).count == 1,
                "the images do not share one bitmap representation at \(scale)x")
        #expect(bitmaps[0].width == Int(14 * scale), "the bitmap is not at the asked scale")
        // Another size is another key.
        let other = try #require(Self.bitmap(NSImage.icon(.search, size: 18), side: 18, scale: scale))
        #expect(ObjectIdentifier(other) != ObjectIdentifier(bitmaps[0]))
    }

    @Test func identicalSystemSymbolsShareOneBitmapPerKey() throws {
        let images = (0..<8).map { _ in NSImage.icon(symbol: "chevron.down", size: 12) }
        let bitmaps = try images.map { try #require(Self.bitmap($0, side: 12, scale: 2)) }
        #expect(Set(bitmaps.map(ObjectIdentifier.init)).count == 1)
        let templates = images.filter(\.isTemplate).count
        #expect(templates == images.count, "a chrome glyph is a template: its tint comes from the view")
    }

    /// Each caller still gets its own image: setting one image's size or description changes no other.
    @Test func eachCallerOwnsItsImage() {
        let first = NSImage.icon(.search, size: 14), second = NSImage.icon(.search, size: 14)
        first.accessibilityDescription = "Search"
        first.size = NSSize(width: 20, height: 20)
        #expect(first !== second)
        #expect(second.accessibilityDescription == nil)
        #expect(second.size == NSSize(width: 14, height: 14))
    }
}
