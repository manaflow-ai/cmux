#if canImport(UIKit)
import Testing

@testable import CmuxMobileTerminal

@Suite("Terminal native scroll geometry")
struct TerminalNativeScrollGeometryTests {
    @Test("scroll range matches Ghostty's real history boundaries")
    func realHistoryRange() {
        let geometry = TerminalNativeScrollGeometry(
            totalRows: 100,
            viewportOffsetRows: 40,
            visibleRows: 20,
            cellHeight: 18,
            viewportHeight: 360
        )

        #expect(geometry.maximumContentOffsetY == 1_440)
        #expect(geometry.contentHeight == 1_800)
        #expect(geometry.authoritativeContentOffsetY == 720)
    }

    @Test("point movement preserves UIKit's continuous velocity")
    func pointMovementProducesFractionalRows() {
        let geometry = TerminalNativeScrollGeometry(
            totalRows: 100,
            viewportOffsetRows: 40,
            visibleRows: 20,
            cellHeight: 20,
            viewportHeight: 400
        )

        let sample = geometry.sample(rawOffsetY: 805, previousEffectiveOffsetY: 800)

        #expect(sample.effectiveOffsetY == 805)
        #expect(sample.rowDelta == -0.25)
        #expect(sample.contentTranslationY == 0)
    }

    @Test("top rubber band does not emit a reverse terminal scroll")
    func topRubberBand() {
        let geometry = TerminalNativeScrollGeometry(
            totalRows: 100,
            viewportOffsetRows: 0,
            visibleRows: 20,
            cellHeight: 20,
            viewportHeight: 400
        )

        let outward = geometry.sample(rawOffsetY: -30, previousEffectiveOffsetY: 0)
        let returning = geometry.sample(rawOffsetY: -10, previousEffectiveOffsetY: outward.effectiveOffsetY)

        #expect(outward.rowDelta == 0)
        #expect(outward.contentTranslationY == 30)
        #expect(returning.rowDelta == 0)
        #expect(returning.contentTranslationY == 10)
    }

    @Test("bottom rubber band does not emit a reverse terminal scroll")
    func bottomRubberBand() {
        let geometry = TerminalNativeScrollGeometry(
            totalRows: 100,
            viewportOffsetRows: 80,
            visibleRows: 20,
            cellHeight: 20,
            viewportHeight: 400
        )
        let maximum = geometry.maximumContentOffsetY

        let outward = geometry.sample(rawOffsetY: maximum + 24, previousEffectiveOffsetY: maximum)
        let returning = geometry.sample(
            rawOffsetY: maximum + 8,
            previousEffectiveOffsetY: outward.effectiveOffsetY
        )

        #expect(outward.rowDelta == 0)
        #expect(outward.contentTranslationY == -24)
        #expect(returning.rowDelta == 0)
        #expect(returning.contentTranslationY == -8)
    }

    @Test("sub-row movement translates content pixel-for-pixel between row flips")
    func presentationTranslationSmoothsSubRowMovement() {
        let geometry = TerminalNativeScrollGeometry(
            totalRows: 100,
            viewportOffsetRows: 40,
            visibleRows: 20,
            cellHeight: 20,
            viewportHeight: 400
        )

        // Finger 5pt above the rendered row position: content follows by 5pt.
        #expect(geometry.presentationTranslation(rawOffsetY: 795, effectiveOffsetY: 795) == 5)
        // Aligned with the rendered row: no translation.
        #expect(geometry.presentationTranslation(rawOffsetY: 800, effectiveOffsetY: 800) == 0)
        // Finger 5pt below: content follows the other way.
        #expect(geometry.presentationTranslation(rawOffsetY: 805, effectiveOffsetY: 805) == -5)
    }

    @Test("presentation compensation is clamped when the renderer lags")
    func presentationTranslationClampsRendererLag() {
        let geometry = TerminalNativeScrollGeometry(
            totalRows: 100,
            viewportOffsetRows: 40,
            visibleRows: 20,
            cellHeight: 20,
            viewportHeight: 400
        )

        // Renderer four rows behind the finger: compensation stops at two rows.
        #expect(geometry.presentationTranslation(rawOffsetY: 720, effectiveOffsetY: 720) == 40)
        #expect(geometry.presentationTranslation(rawOffsetY: 880, effectiveOffsetY: 880) == -40)
    }

    @Test("presentation translation preserves rubber-band overdrag")
    func presentationTranslationPreservesRubberBand() {
        let geometry = TerminalNativeScrollGeometry(
            totalRows: 100,
            viewportOffsetRows: 80,
            visibleRows: 20,
            cellHeight: 20,
            viewportHeight: 400
        )
        let maximum = geometry.maximumContentOffsetY

        #expect(
            geometry.presentationTranslation(
                rawOffsetY: maximum + 24,
                effectiveOffsetY: maximum
            ) == -24
        )
    }

    @Test("appended history extends the range without moving a held viewport")
    func appendedOutputPreservesHeldViewport() {
        let before = TerminalNativeScrollGeometry(
            totalRows: 100,
            viewportOffsetRows: 40,
            visibleRows: 20,
            cellHeight: 20,
            viewportHeight: 400
        )
        let after = TerminalNativeScrollGeometry(
            totalRows: 160,
            viewportOffsetRows: 40,
            visibleRows: 20,
            cellHeight: 20,
            viewportHeight: 400
        )

        #expect(after.authoritativeContentOffsetY == before.authoritativeContentOffsetY)
        #expect(after.maximumContentOffsetY > before.maximumContentOffsetY)
    }

    @Test("primary screen without authoritative bounds fails closed")
    func zeroRangeFailsClosed() {
        let geometry = TerminalNativeScrollGeometry.zeroRange(
            cellHeight: 20,
            viewportHeight: 400
        )

        #expect(geometry.maximumContentOffsetY == 0)
        #expect(geometry.contentHeight == 400)
        #expect(geometry.authoritativeContentOffsetY == 0)

        let overdrag = geometry.sample(rawOffsetY: 48, previousEffectiveOffsetY: 0)
        #expect(overdrag.effectiveOffsetY == 0)
        #expect(overdrag.rowDelta == 0)
        #expect(overdrag.contentTranslationY == -48)
    }

    @Test("zero-range geometry survives a zero cell height")
    func zeroRangeToleratesZeroCellHeight() {
        let geometry = TerminalNativeScrollGeometry.zeroRange(
            cellHeight: 0,
            viewportHeight: 400
        )

        let sample = geometry.sample(rawOffsetY: -30, previousEffectiveOffsetY: 0)
        #expect(sample.rowDelta == 0)
        #expect(sample.contentTranslationY == 30)
    }

    @Test("pending precise scroll prevents stale authoritative resync")
    func pendingScrollDefersResync() {
        #expect(!TerminalNativeScrollGeometry.shouldSynchronize(
            explicitlyRequested: false,
            isInteracting: false,
            hasPendingScroll: true
        ))
        #expect(TerminalNativeScrollGeometry.shouldSynchronize(
            explicitlyRequested: false,
            isInteracting: false,
            hasPendingScroll: false
        ))
    }
}
#endif
