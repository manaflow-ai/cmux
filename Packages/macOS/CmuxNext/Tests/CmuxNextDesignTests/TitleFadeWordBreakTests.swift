import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Leo 2026-11-23 ("opening a new tab in a pane with many tabs the end bit the text has a weird rewritten thing"):
/// every crowded "New Tab" read "New" and a faint tick at cap height. The trailing fade ended a few points into the
/// "T", so the left end of its crossbar showed, faded, after the space: a fragment that reads as no letter. A fade
/// never ends inside the first glyph of a word after a space; it ends at that word's start instead.
@MainActor @Suite struct TitleFadeWordBreakTests {
    /// "New Tab" in the 12 pt tab title font, measured on its line.
    static func newTab(font: NSFont = .systemFont(ofSize: 12)) -> (layer: ChromeTextLayer, t: TitleFadeGeometry.WordStart) {
        let layer = ChromeTextLayer()
        layer.font = font
        layer.string = "New Tab"
        return (layer, layer.wordStarts[0])
    }

    @Test func aTitleMeasuresWhereEachWordAfterASpaceStarts() throws {
        let layer = ChromeTextLayer()
        layer.font = .systemFont(ofSize: 12)
        layer.string = "Agent  session — long"
        let starts = layer.wordStarts
        // "session", "—", "long": runs of spaces count once, the first word is never a break.
        #expect(starts.count == 3)
        let new = Self.newTab()
        let newWidth = ("New " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        #expect(abs(new.t.x - newWidth) <= 0.5, "the T starts at \(new.t.x), \"New \" is \(newWidth) wide")
        #expect(new.t.firstGlyphEnd > new.t.x + 4, "the T is \(new.t.firstGlyphEnd - new.t.x) pt wide")
        layer.string = "127.0.0.1:8080"
        #expect(layer.wordStarts.isEmpty)
    }

    /// The crowded strip in Leo's video, at every width its tabs took while they opened and settled: no visible
    /// width ends the fade inside the T.
    @Test func newTabNeverShowsAFragmentOfItsT() {
        let (layer, t) = Self.newTab()
        let textWidth = layer.textWidth
        for tenth in 0...Int(textWidth * 10) {
            let visible = CGFloat(tenth) / 10
            let geometry = TitleFadeGeometry(textWidth: textWidth, span: visible + 14, visibleWidth: visible, leadingPadding: 6,
                                             trailingPadding: 0, fadeWidth: 20, wordStarts: layer.wordStarts)
            guard geometry.isTruncated else { continue }
            let cutsT = geometry.fadeEnd > t.x + 0.01 && geometry.fadeEnd < t.firstGlyphEnd - 0.01
            #expect(!cutsT, "at \(visible) pt the fade ends at \(geometry.fadeEnd), inside the T (\(t.x)–\(t.firstGlyphEnd))")
            #expect(geometry.fadeEnd <= geometry.clearEdge)
        }
    }

    @Test func aFadeInsideANextWordsFirstGlyphEndsAtThatWord() {
        let words = [TitleFadeGeometry.WordStart(x: 27.6, firstGlyphEnd: 34.9)]
        // Leo's frames: the clear edge 3 pt into the T.
        let cut = TitleFadeGeometry(textWidth: 46, span: 40, visibleWidth: 30.6, leadingPadding: 6, trailingPadding: 0,
                                    fadeWidth: 20, wordStarts: words)
        #expect(cut.fadeEnd == 27.6)
        #expect(abs(cut.fadeStart - 13.8) < 0.0001)
        // The stops carry it: clear from the T's start on.
        #expect(abs(cut.maskLocations[3] - (6 + 27.6) / 46) < 0.0001)
        // Past the T's first glyph the fade is the plain one (the T reads as a T, then "Ta", "Tab").
        let past = TitleFadeGeometry(textWidth: 46, span: 44, visibleWidth: 38, leadingPadding: 6, trailingPadding: 0,
                                     fadeWidth: 20, wordStarts: words)
        #expect(past.fadeEnd == 38)
        // In the space itself nothing of the T shows: unchanged.
        let space = TitleFadeGeometry(textWidth: 46, span: 40, visibleWidth: 26, leadingPadding: 6, trailingPadding: 0,
                                      fadeWidth: 20, wordStarts: words)
        #expect(space.fadeEnd == 26)
        // A title that fits is not faded at all.
        let fits = TitleFadeGeometry(textWidth: 30, span: 40, visibleWidth: 30.5, leadingPadding: 6, trailingPadding: 0,
                                     fadeWidth: 20, wordStarts: words)
        #expect(fits.fadeEnd == 30.5)
    }

    /// A first word too long to fit has no break before the edge: it keeps the glyph fade.
    @Test func aLongFirstWordKeepsTheGlyphFade() {
        let layer = ChromeTextLayer()
        layer.font = .systemFont(ofSize: 12)
        layer.string = "127.0.0.1:8080 / a very long browser title"
        let geometry = TitleFadeGeometry(textWidth: layer.textWidth, span: 40, visibleWidth: 34, leadingPadding: 6,
                                         trailingPadding: 0, fadeWidth: 20, wordStarts: layer.wordStarts)
        #expect(geometry.fadeEnd == 34)
    }

    /// The sidebar's title (`MarqueeLabel`, a workspace row) lays its fade out with the same rule.
    @Test func aMarqueeLabelEndsItsFadeAtAWordStart() throws {
        let (_, t) = Self.newTab()
        let label = MarqueeLabel(gate: Motion.sidebar, frame: NSRect(x: 0, y: 0, width: t.x + 2, height: 16))
        label.font = .systemFont(ofSize: 12)
        label.stringValue = "New Tab"
        label.layout()
        let text = try #require(label.layer?.sublayers?.first)
        let mask = try #require(text.mask as? CAGradientLayer, "a clipped label has no fade mask")
        let clear = try #require(mask.locations?[3]).doubleValue * mask.bounds.width + mask.frame.minX
        #expect(abs(clear - t.x) <= 0.5, "the label's fade clears at \(clear), the T starts at \(t.x)")
    }
}
