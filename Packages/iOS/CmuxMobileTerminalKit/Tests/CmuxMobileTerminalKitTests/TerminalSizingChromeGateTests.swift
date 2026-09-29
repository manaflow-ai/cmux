import Testing
@testable import CmuxMobileTerminalKit

@Suite struct TerminalSizingChromeGateTests {
    private func decoration(
        grid: (Int, Int) = (175, 78),
        viewer: (Int, Int) = (54, 44),
        confirmed: Bool = true
    ) -> TerminalSizingBoundsDecoration {
        TerminalSizingBoundsDecoration(
            gridColumns: grid.0, gridRows: grid.1,
            viewerColumns: viewer.0, viewerRows: viewer.1,
            viewportConfirmed: confirmed
        )
    }

    @Test func noSizeStateDrawsNothing() {
        #expect(!TerminalSizingChromeGate.drawsChrome(decoration: nil, viewportReportPending: false))
    }

    @Test func settledMismatchDraws() {
        #expect(TerminalSizingChromeGate.drawsChrome(decoration: decoration(), viewportReportPending: false))
    }

    @Test func matchingGridDrawsNothing() {
        #expect(!TerminalSizingChromeGate.drawsChrome(
            decoration: decoration(grid: (54, 44)), viewportReportPending: false
        ))
    }

    /// Connect: the first size state still lists the phone's old viewport.
    @Test func stateForAnOlderViewportDrawsNothing() {
        #expect(!TerminalSizingChromeGate.drawsChrome(
            decoration: decoration(confirmed: false), viewportReportPending: false
        ))
    }

    /// Keyboard or rotation: a report is queued or in flight.
    @Test func pendingReportDrawsNothing() {
        #expect(!TerminalSizingChromeGate.drawsChrome(decoration: decoration(), viewportReportPending: true))
    }

    @Test func plainLetterboxWaitsForTheReport() {
        #expect(TerminalSizingChromeGate.drawsPlainLetterboxBorder(isLetterboxed: true, viewportReportPending: false))
        #expect(!TerminalSizingChromeGate.drawsPlainLetterboxBorder(isLetterboxed: true, viewportReportPending: true))
        #expect(!TerminalSizingChromeGate.drawsPlainLetterboxBorder(isLetterboxed: false, viewportReportPending: false))
    }
}
