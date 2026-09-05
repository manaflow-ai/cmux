import Testing

@testable import CmuxMobileTerminal

@Suite("Accessory leading-edge scroll fade")
struct AccessoryEdgeFadeTests {
    @Test("edge stays fully opaque at rest and during leading bounce")
    func opaqueAtRest() {
        #expect(AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: 0) == 1)
        // Rest position when the host carries the 4pt inter-button gap as a
        // leading content inset: still no fade until a key reaches the edge.
        #expect(AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: -4) == 1)
        #expect(AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: -30) == 1)
    }

    @Test("fade ramps linearly with the first points of scroll")
    func incrementalRamp() {
        let quarter = AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: 6, fadeWidth: 24)
        let half = AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: 12, fadeWidth: 24)
        #expect(abs(quarter - 0.75) < 0.0001)
        #expect(abs(half - 0.5) < 0.0001)
    }

    @Test("fade saturates once scrolled a full band width")
    func saturates() {
        #expect(AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: 24, fadeWidth: 24) == 0)
        #expect(AccessoryEdgeFadeScrollView.leadingEdgeAlpha(contentOffsetX: 500, fadeWidth: 24) == 0)
    }

    @Test("band fraction spans the band, clamped to degenerate viewports")
    func bandFraction() {
        #expect(abs(AccessoryEdgeFadeScrollView.fadeBandFraction(viewportWidth: 240, fadeWidth: 24) - 0.1) < 0.0001)
        #expect(AccessoryEdgeFadeScrollView.fadeBandFraction(viewportWidth: 10, fadeWidth: 24) == 1)
        #expect(AccessoryEdgeFadeScrollView.fadeBandFraction(viewportWidth: 0, fadeWidth: 24) == 0)
    }
}
