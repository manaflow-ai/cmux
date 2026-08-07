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

    @Test("pending precise scroll prevents stale authoritative resync")
    func pendingScrollDefersResync() {
        #expect(!TerminalNativeScrollSynchronization.shouldSynchronize(
            explicitlyRequested: false,
            isInteracting: false,
            hasPendingScroll: true
        ))
        #expect(TerminalNativeScrollSynchronization.shouldSynchronize(
            explicitlyRequested: false,
            isInteracting: false,
            hasPendingScroll: false
        ))
    }
}
#endif
