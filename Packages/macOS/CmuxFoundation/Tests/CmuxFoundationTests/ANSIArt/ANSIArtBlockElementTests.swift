import CoreGraphics
import Testing

@testable import CmuxFoundation

/// Behavior tests for ``ANSIArtBlockElement`` cell geometry.
@Suite struct ANSIArtBlockElementTests {
    @Test func halfBlocksCoverTheirHalf() throws {
        #expect(try #require(ANSIArtBlockElement("▀")).rects == [CGRect(x: 0, y: 0, width: 1, height: 0.5)])
        #expect(try #require(ANSIArtBlockElement("▄")).rects == [CGRect(x: 0, y: 0.5, width: 1, height: 0.5)])
        #expect(try #require(ANSIArtBlockElement("▌")).rects == [CGRect(x: 0, y: 0, width: 0.5, height: 1)])
        #expect(try #require(ANSIArtBlockElement("▐")).rects == [CGRect(x: 0.5, y: 0, width: 0.5, height: 1)])
        #expect(try #require(ANSIArtBlockElement("█")).rects == [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }

    @Test func eighthsAndQuadrants() throws {
        #expect(try #require(ANSIArtBlockElement("▁")).rects == [CGRect(x: 0, y: 0.875, width: 1, height: 0.125)])
        #expect(try #require(ANSIArtBlockElement("▏")).rects == [CGRect(x: 0, y: 0, width: 0.125, height: 1)])
        #expect(try #require(ANSIArtBlockElement("▉")).rects == [CGRect(x: 0, y: 0, width: 0.875, height: 1)])
        #expect(try #require(ANSIArtBlockElement("▚")).rects == [
            CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ])
        #expect(try #require(ANSIArtBlockElement("▟")).rects.count == 3)
    }

    @Test func shadesFillTheCellTranslucently() throws {
        let light = try #require(ANSIArtBlockElement("░"))
        #expect(light.rects == [CGRect(x: 0, y: 0, width: 1, height: 1)])
        #expect(light.opacity == 0.25)
        #expect(try #require(ANSIArtBlockElement("▓")).opacity == 0.75)
        #expect(try #require(ANSIArtBlockElement("▀")).opacity == 1)
    }

    @Test func otherCharactersAreNotBlocks() {
        #expect(ANSIArtBlockElement("A") == nil)
        #expect(ANSIArtBlockElement("─") == nil)
        #expect(ANSIArtBlockElement("\u{25A0}") == nil)
    }
}
