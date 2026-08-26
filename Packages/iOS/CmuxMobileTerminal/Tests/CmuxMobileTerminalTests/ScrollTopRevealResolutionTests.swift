#if canImport(UIKit)
import CmuxMobileTerminalKit
import Testing

/// The combined scroll axis for the keyboard-up presentation: grid scrollback
/// position plus the top-reveal zone past scrollback-top. The reveal zone is
/// what makes the oldest rows reachable while the keyboard is up — the
/// bottom-pinned full-height render clips its top `maxRevealPx` above the
/// screen, and grid scrolling alone clamps at position 0 with those rows
/// still hidden.
@Suite("Scroll top-reveal axis")
struct ScrollTopRevealResolutionTests {
    @Test("pulling past scrollback-top extends into the reveal zone")
    func pullingPastTopExtendsIntoReveal() {
        let resolved = TerminalLetterboxGeometry.scrollTopRevealResolution(
            currentPositionPx: 100,
            currentRevealPx: 0,
            deltaPixels: -300,
            maxPositionPx: 1_000,
            maxRevealPx: 250
        )
        #expect(resolved.positionPx == 0)
        #expect(resolved.revealPx == 200)
    }

    @Test("reveal clamps at the clipped-top budget")
    func revealClampsAtBudget() {
        let resolved = TerminalLetterboxGeometry.scrollTopRevealResolution(
            currentPositionPx: 0,
            currentRevealPx: 200,
            deltaPixels: -500,
            maxPositionPx: 1_000,
            maxRevealPx: 250
        )
        #expect(resolved.positionPx == 0)
        #expect(resolved.revealPx == 250)
    }

    @Test("scrolling toward newer content consumes the reveal before the grid moves")
    func scrollDownConsumesRevealFirst() {
        let partway = TerminalLetterboxGeometry.scrollTopRevealResolution(
            currentPositionPx: 0,
            currentRevealPx: 250,
            deltaPixels: 100,
            maxPositionPx: 1_000,
            maxRevealPx: 250
        )
        #expect(partway.positionPx == 0)
        #expect(partway.revealPx == 150)

        let through = TerminalLetterboxGeometry.scrollTopRevealResolution(
            currentPositionPx: 0,
            currentRevealPx: 250,
            deltaPixels: 400,
            maxPositionPx: 1_000,
            maxRevealPx: 250
        )
        #expect(through.positionPx == 150)
        #expect(through.revealPx == 0)
    }

    @Test("a zero budget hard-zeroes a stale reveal instead of shifting the grid")
    func zeroBudgetIgnoresStaleReveal() {
        let resolved = TerminalLetterboxGeometry.scrollTopRevealResolution(
            currentPositionPx: 500,
            currentRevealPx: 120,
            deltaPixels: -100,
            maxPositionPx: 1_000,
            maxRevealPx: 0
        )
        #expect(resolved.positionPx == 400)
        #expect(resolved.revealPx == 0)
    }

    @Test("a shrunken budget clamps a held reveal before the delta applies")
    func shrunkenBudgetClampsHeldReveal() {
        let resolved = TerminalLetterboxGeometry.scrollTopRevealResolution(
            currentPositionPx: 0,
            currentRevealPx: 250,
            deltaPixels: 0,
            maxPositionPx: 1_000,
            maxRevealPx: 100
        )
        #expect(resolved.positionPx == 0)
        #expect(resolved.revealPx == 100)
    }

    @Test("the bottom clamp is unchanged")
    func bottomClampUnchanged() {
        let resolved = TerminalLetterboxGeometry.scrollTopRevealResolution(
            currentPositionPx: 900,
            currentRevealPx: 0,
            deltaPixels: 300,
            maxPositionPx: 1_000,
            maxRevealPx: 250
        )
        #expect(resolved.positionPx == 1_000)
        #expect(resolved.revealPx == 0)
    }
}
#endif
