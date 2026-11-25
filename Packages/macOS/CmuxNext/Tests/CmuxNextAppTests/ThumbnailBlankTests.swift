import AppKit
import CmuxNextBridge
import CoreText
import Testing

/// The user, 2026-11-24: a terminal with output and a chat showed an empty tile in their hover cards. A dark pane with
/// a few short lines of text was measured blank (a 16x16 variance under 4) and its real picture dropped. A picture
/// with any text is a picture; a flat one (a page that had not painted, a cleared terminal) is still blank.
struct ThumbnailBlankTests {
    /// A dark pane the size a hover card asks for, with `lines` drawn top-left as a terminal or chat shows them.
    static func pane(_ lines: [String], width: Int = 640, height: Int = 400, ground: CGFloat = 0.11) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: ground, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor(white: 0.85, alpha: 1)])
            context.textPosition = CGPoint(x: 8, y: CGFloat(height) - 18 - CGFloat(index) * 16)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        return context.makeImage()!
    }

    @Test func aDarkTerminalWithOneLineOfOutputIsAPicture() {
        let image = Self.pane(["you@mac ~ % ls", "README.md"])
        let stats = ThumbnailStats.measured(image)!
        #expect(!stats.isBlank, "a terminal with output was measured blank: \(stats)")
    }

    @Test func aLargeDarkTerminalWithTwoLinesIsAPicture() {
        // Was variance 0.39 over the 16x16 copy: dropped as blank.
        #expect(!ThumbnailStats.measured(Self.pane(["you@mac ~ % ls", "README.md"], width: 1800, height: 1100))!.isBlank)
    }

    @Test func aChatWithItsFirstTurnIsAPicture() {
        let image = Self.pane(["", "", "Fix the sidebar border", "", "Done."], width: 1280, height: 800)
        #expect(!ThumbnailStats.measured(image)!.isBlank)
    }

    @Test func aFlatCaptureIsBlank() {
        #expect(ThumbnailStats.measured(Self.pane([]))!.isBlank)
        #expect(ThumbnailStats.measured(Self.pane([], ground: 0.95))!.isBlank)
        #expect(ThumbnailStats.measured(Self.pane(["%"]))!.isBlank, "a lone prompt glyph is no picture")
    }
}
