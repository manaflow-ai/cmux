import AppKit
@testable import CmuxNextDesign
import Testing

/// A sidebar row's title layer takes the row's width minus its trailing marks, so an agent's
/// working/idle flip (its spinner shown, then gone) narrowed and widened every ticking title, and each
/// width change drew the title's glyphs again with Core Text: the largest part of the Core Animation
/// commit in `sidebar.400.ticking.main_ms_per_s` (stable gate item 3). A left-aligned line that fits
/// both widths draws the same pixels at either, so its glyphs are kept.
@MainActor @Suite(.serialized) struct ChromeTextKeepGlyphsTests {
    private static let height: CGFloat = 16

    private func layer(_ string: String, width: CGFloat, alignment: NSTextAlignment = .left) -> ChromeTextLayer {
        let text = ChromeTextLayer()
        text.contentsScale = 2
        text.font = .systemFont(ofSize: 13)
        text.alignmentMode = alignment
        text.string = string
        text.frame = CGRect(x: 0, y: 0, width: width, height: Self.height)
        show(text)
        return text
    }

    /// Lays the layer out and draws its glyphs, as a commit would.
    private func show(_ text: ChromeTextLayer) {
        text.layoutIfNeeded()
        glyphLayer(text)?.displayIfNeeded()
    }

    private func glyphLayer(_ text: ChromeTextLayer) -> CALayer? {
        text.sublayers?.first?.mask
    }

    private func glyphImage(_ text: ChromeTextLayer) -> CGImage? {
        guard let contents = glyphLayer(text)?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return unsafeDowncast(contents as AnyObject, to: CGImage.self)
    }

    /// The image's RGBA bytes over its leftmost `width` pixels.
    private func bytes(_ image: CGImage, width: Int) -> [UInt8] {
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: height))
        }
        return data
    }

    @Test func aWidthChangeAFittingLineSurvivesDrawsNothing() throws {
        let text = layer("perf-tick-07", width: 200)
        #expect(text.glyphDraws == 1)
        let drawn = try #require(glyphImage(text))
        for width: CGFloat in [180, 200, 172, 200] {
            text.frame.size.width = width
            show(text)
        }
        #expect(text.glyphDraws == 1, "a width change that moves no glyph drew the title again")
        #expect(glyphImage(text) === drawn)
        // The kept glyphs are the pixels a fresh draw at the new width makes.
        text.frame.size.width = 172
        show(text)
        let fresh = layer("perf-tick-07", width: 172)
        let freshImage = try #require(glyphImage(fresh))
        #expect(bytes(drawn, width: freshImage.width) == bytes(freshImage, width: freshImage.width))
        #expect(glyphLayer(text)?.frame.width == 200, "the kept glyphs stay at the width they were drawn for")
    }

    /// A width that cuts into the line, a new string, and an alignment that follows the width all draw again.
    @Test func aChangeThatMovesGlyphsDrawsAgain() {
        let text = layer("perf-tick-07", width: 200)
        text.frame.size.width = 20
        show(text)
        #expect(text.glyphDraws == 2, "a width that clips the line kept the unclipped glyphs")
        #expect(glyphLayer(text)?.frame.width == 20)

        let renamed = layer("perf-tick-07", width: 200)
        renamed.frame.size.width = 180
        renamed.string = "perf-tick-08"
        show(renamed)
        #expect(renamed.glyphDraws == 2)
        #expect(glyphLayer(renamed)?.frame.width == 180, "a redraw after kept glyphs draws at the layer's width")

        let right = layer("perf-tick-07", width: 200, alignment: .right)
        right.frame.size.width = 180
        show(right)
        #expect(right.glyphDraws == 2, "right-aligned glyphs move with the width")
    }

    /// A color that needs other ink draws at the kept width, so the image matches its layer.
    @Test func aNewInkWhileKeptDrawsAtTheKeptWidth() throws {
        let text = layer("perf-tick-07", width: 200)
        text.frame.size.width = 180
        show(text)
        text.foregroundColor = NSColor.white.cgColor
        text.foregroundColor = NSColor.black.cgColor
        show(text)
        let image = try #require(glyphImage(text))
        let glyphs = try #require(glyphLayer(text))
        #expect(CGFloat(image.width) == (glyphs.frame.width * 2).rounded(.up))
    }
}
