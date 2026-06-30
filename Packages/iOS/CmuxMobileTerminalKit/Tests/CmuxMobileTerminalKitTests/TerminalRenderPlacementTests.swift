import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalRenderPlacement")
struct TerminalRenderPlacementTests {
    private let placement = TerminalRenderPlacement()

    @Test("large shorter render starts at the viewport top")
    func renderRectLargeShorterRenderStartsAtTop() {
        let rect = placement.renderRect(
            in: CGRect(x: 0, y: 0, width: 402, height: 700),
            size: CGSize(width: 402, height: 360)
        )
        #expect(rect.minY == 0)
        #expect(rect.height == 360)
    }

    @Test("stale natural render stays bottom attached during viewport growth")
    func renderRectStaleNaturalRenderStaysBottomAttached() {
        let rect = placement.renderRect(
            in: CGRect(x: 0, y: 0, width: 402, height: 700),
            size: CGSize(width: 402, height: 360),
            allowsLargeTopGapCorrection: false
        )
        #expect(rect.minY == 340)
        #expect(rect.maxY == 700)
    }

    @Test("small whole-cell remainder stays bottom attached")
    func renderRectSmallRemainderStaysBottomAttached() {
        let rect = placement.renderRect(
            in: CGRect(x: 0, y: 0, width: 402, height: 700),
            size: CGSize(width: 402, height: 680)
        )
        #expect(rect.minY == 20)
        #expect(rect.maxY == 700)
    }

    @Test("oversized render stays bottom pinned for keyboard shrink")
    func renderRectOversizedRenderStaysBottomPinned() {
        let rect = placement.renderRect(
            in: CGRect(x: 0, y: 0, width: 402, height: 400),
            size: CGSize(width: 402, height: 700)
        )
        #expect(rect.minY == -300)
        #expect(rect.maxY == 400)
    }

    @Test("large top-gap correction requires a pinned render")
    func topGapCorrectionRequiresPinnedRender() {
        let allowed = placement.allowsLargeTopGapCorrection(
            pinnedGrid: nil,
            awaitingViewportEcho: nil,
            naturalGrid: (cols: 100, rows: 40),
            previousRenderAllowedTopGapCorrection: false
        )
        #expect(!allowed)
    }

    @Test("pinned render can top-anchor when no local viewport echo is pending")
    func topGapCorrectionAllowsAuthoritativePinnedRender() {
        let allowed = placement.allowsLargeTopGapCorrection(
            pinnedGrid: (cols: 80, rows: 24),
            awaitingViewportEcho: nil,
            naturalGrid: (cols: 100, rows: 40),
            previousRenderAllowedTopGapCorrection: false
        )
        #expect(allowed)
    }

    @Test("stale local viewport echo keeps pinned render bottom attached")
    func topGapCorrectionRejectsStaleLocalViewportEcho() {
        let allowed = placement.allowsLargeTopGapCorrection(
            pinnedGrid: (cols: 100, rows: 24),
            awaitingViewportEcho: (cols: 100, rows: 40),
            naturalGrid: (cols: 100, rows: 40),
            previousRenderAllowedTopGapCorrection: false
        )
        #expect(!allowed)
    }

    @Test("already top-corrected letterbox keeps top correction during relayout")
    func topGapCorrectionPreservesExistingIntentionalLetterbox() {
        let allowed = placement.allowsLargeTopGapCorrection(
            pinnedGrid: (cols: 80, rows: 24),
            awaitingViewportEcho: (cols: 100, rows: 40),
            naturalGrid: (cols: 100, rows: 40),
            previousRenderAllowedTopGapCorrection: true
        )
        #expect(allowed)
    }

    @Test("grid cell maps points inside the rendered terminal")
    func gridCellMapsInsideRenderRect() {
        let cell = placement.gridCell(
            at: CGPoint(x: 42, y: 72),
            in: CGRect(x: 10, y: 20, width: 200, height: 100),
            cellSize: CGSize(width: 8, height: 10)
        )
        #expect(cell?.col == 4)
        #expect(cell?.row == 5)
    }

    @Test("grid cell ignores bottom letterbox margin")
    func gridCellIgnoresBottomLetterboxMargin() {
        let cell = placement.gridCell(
            at: CGPoint(x: 42, y: 150),
            in: CGRect(x: 10, y: 20, width: 200, height: 100),
            cellSize: CGSize(width: 8, height: 10)
        )
        #expect(cell == nil)
    }
}
