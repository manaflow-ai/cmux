import AppKit
import CmuxNextSettings
import Testing

/// The menu bar item shows cmux-classic's icon (user 2026-10-28: "cmux-next menubar logo needs to be
/// same icon as cmux-classic"): an 18 by 18 pt template image with the cmux chevron in classic's glyph
/// rect (x 1.2, y 1.5, 11.6 by 15), so the shape, size and light/dark rendering match classic's item.
@MainActor
struct MenuBarIconTests {
    /// The image drawn at 1x into an 18 by 18 pixel bitmap; row 0 is the top row.
    private static func bitmap() throws -> NSBitmapImageRep {
        let image = MenuBarIcon().image()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    @Test func isClassicsSizeAndATemplate() {
        let image = MenuBarIcon().image()
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate)
    }

    @Test func drawsClassicsChevron() throws {
        let rep = try Self.bitmap()
        // The upper arm near the left edge and the tip on the right are filled.
        #expect(Self.alpha(rep, 2, 3) > 0.9)
        #expect(Self.alpha(rep, 10, 8) > 0.9)
        // The notch between the arms is empty, and so are the corners outside the glyph rect.
        #expect(Self.alpha(rep, 2, 8) < 0.1)
        #expect(Self.alpha(rep, 16, 1) < 0.1)
        #expect(Self.alpha(rep, 16, 16) < 0.1)
        #expect(Self.alpha(rep, 0, 0) < 0.1)
    }
}
