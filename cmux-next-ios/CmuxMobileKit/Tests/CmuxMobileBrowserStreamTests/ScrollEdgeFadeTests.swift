import CmuxMobileDesign
import Testing

/// The shared edge fade is the terminal key row's: 24 pt, in proportion to what is past the edge.
@Suite struct ScrollEdgeFadeTests {
    @Test func fadeMatchesTheTerminalKeyRow() {
        let fade = ScrollEdgeFade()
        #expect(ScrollEdgeFade.width == 24)
        #expect(fade.edgeAlpha(hidden: 0) == 1)
        #expect(fade.edgeAlpha(hidden: 12) == 0.5)
        #expect(fade.edgeAlpha(hidden: 200) == 0)
        #expect(fade.edgeAlpha(hidden: -30) == 1)
        let edges = fade.edgeAlphas(offset: 6, visibleWidth: 100, contentWidth: 112)
        #expect(edges.left == 0.75)
        #expect(edges.right == 0.75)
    }
}
