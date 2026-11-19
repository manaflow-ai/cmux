import CoreGraphics
@testable import CmuxNextSidebar
import Testing

/// The pure optical-size rule (`SidebarOpticalGlyph`): an image's ink, not its square, takes the target size.
@Suite struct SidebarOpticalGlyphTests {
    let optics = SidebarOpticalGlyph(target: 16)

    @Test func aMarginedImageDrawsLargerSoItsInkMatches() throws {
        // A 32 pt app icon whose ink is the middle 24 pt: drawn at 16 x 4/3, its ink is 16.
        let frame = try #require(optics.frame(imageSize: CGSize(width: 32, height: 32), ink: CGRect(x: 4, y: 4, width: 24, height: 24),
                                              leading: 10, centerY: 12, flipped: true, scale: 2))
        #expect(abs(frame.width - CGFloat(32) * 16 / 24) <= 0.25, "the image draws at \(frame.width)")
        #expect(abs(frame.minX + 4 * frame.width / 32 - 10) <= 0.25, "the ink starts at the leading edge")
        #expect((frame.width * 2).rounded() == frame.width * 2, "the size is on the 2x pixel grid")
    }

    @Test func aTallGlyphTakesTheSizeOnItsLongerSide() throws {
        // A pin: 6 x 14 ink in a 16 pt square.
        let frame = try #require(optics.frame(imageSize: CGSize(width: 16, height: 16), ink: CGRect(x: 5, y: 1, width: 6, height: 14),
                                              leading: 0, centerY: 12, flipped: true, scale: 2))
        let k = frame.width / 16
        #expect(abs(14 * k - 16) <= 0.25)
        #expect(abs(frame.minY + 8 * k - 12) <= 0.25, "the ink centers on the row")
    }

    @Test(arguments: [12.0, 15, 16.5, 18, 20])
    func rasterBoxesKeepGlyphInkInOneSlot(box: CGFloat) throws {
        let optics = SidebarOpticalGlyph(target: box * 0.75, box: box)
        let inks = [CGRect(x: 2, y: 2, width: 12, height: 12), CGRect(x: 5, y: 1, width: 6, height: 14)]
        for ink in inks {
            let frame = try #require(optics.frame(imageSize: CGSize(width: 16, height: 16), ink: ink,
                                                  leading: 10, centerY: 16, flipped: true, scale: 2))
            let k = frame.width / 16
            #expect(abs(SidebarOpticalGlyph.fittedExtent(ink.size) * k - optics.target) <= 0.5)
            #expect(abs(frame.minX + ink.midX * k - (10 + optics.target / 2)) <= 0.5)
        }
    }

    @Test func emptyInkDrawsNothing() {
        #expect(optics.frame(imageSize: CGSize(width: 16, height: 16), ink: .zero, leading: 0, centerY: 0, flipped: true, scale: 2) == nil)
    }
}
