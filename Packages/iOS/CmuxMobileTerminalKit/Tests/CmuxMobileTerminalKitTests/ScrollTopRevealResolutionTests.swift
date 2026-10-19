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

/// The line-path variant of the reveal axis: no grid position exists (wheel
/// lines are TUI input with an unknowable extent), so the reveal resolves
/// FIRST in both directions and the leftover delta is what reaches the app.
@Suite("Line-path scroll top-reveal resolution")
struct LineScrollTopRevealResolutionTests {
    @Test("toward older content the reveal fills before any wheel delta leaks")
    func olderFillsRevealFirst() {
        let within = TerminalLetterboxGeometry.lineScrollTopRevealResolution(
            currentRevealPx: 0,
            deltaPixels: -180,
            maxRevealPx: 250
        )
        #expect(within.revealPx == 180)
        #expect(within.leftoverDeltaPixels == 0)

        let past = TerminalLetterboxGeometry.lineScrollTopRevealResolution(
            currentRevealPx: 180,
            deltaPixels: -200,
            maxRevealPx: 250
        )
        #expect(past.revealPx == 250)
        #expect(past.leftoverDeltaPixels == -130)
    }

    @Test("toward newer content the reveal drains before any wheel delta leaks")
    func newerDrainsRevealFirst() {
        let within = TerminalLetterboxGeometry.lineScrollTopRevealResolution(
            currentRevealPx: 250,
            deltaPixels: 100,
            maxRevealPx: 250
        )
        #expect(within.revealPx == 150)
        #expect(within.leftoverDeltaPixels == 0)

        let past = TerminalLetterboxGeometry.lineScrollTopRevealResolution(
            currentRevealPx: 150,
            deltaPixels: 400,
            maxRevealPx: 250
        )
        #expect(past.revealPx == 0)
        #expect(past.leftoverDeltaPixels == 250)
    }

    @Test("a zero budget drops a stale reveal without converting it into wheel delta")
    func zeroBudgetDropsStaleReveal() {
        let resolved = TerminalLetterboxGeometry.lineScrollTopRevealResolution(
            currentRevealPx: 120,
            deltaPixels: -100,
            maxRevealPx: 0
        )
        #expect(resolved.revealPx == 0)
        #expect(resolved.leftoverDeltaPixels == -100)
    }

    @Test("a shrunken budget clamps a held reveal before the delta applies")
    func shrunkenBudgetClampsHeldReveal() {
        let resolved = TerminalLetterboxGeometry.lineScrollTopRevealResolution(
            currentRevealPx: 250,
            deltaPixels: 0,
            maxRevealPx: 100
        )
        #expect(resolved.revealPx == 100)
        #expect(resolved.leftoverDeltaPixels == 0)
    }
}
