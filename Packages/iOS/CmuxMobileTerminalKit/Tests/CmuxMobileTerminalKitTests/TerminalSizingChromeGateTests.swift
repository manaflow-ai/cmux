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
        #expect(!TerminalSizingChromeGate(viewportReportPending: false).drawsChrome(decoration: nil))
    }

    @Test func settledMismatchDraws() {
        #expect(TerminalSizingChromeGate(viewportReportPending: false).drawsChrome(decoration: decoration()))
    }

    @Test func matchingGridDrawsNothing() {
        #expect(!TerminalSizingChromeGate(viewportReportPending: false).drawsChrome(decoration: decoration(grid: (54, 44))))
    }

    /// Connect: the first size state still lists the phone's old viewport.
    @Test func stateForAnOlderViewportDrawsNothing() {
        #expect(!TerminalSizingChromeGate(viewportReportPending: false).drawsChrome(decoration: decoration(confirmed: false)))
    }

    /// Keyboard or rotation: a report is queued or in flight.
    @Test func pendingReportDrawsNothing() {
        #expect(!TerminalSizingChromeGate(viewportReportPending: true).drawsChrome(decoration: decoration()))
    }

    @Test func plainLetterboxWaitsForTheReport() {
        #expect(TerminalSizingChromeGate(viewportReportPending: false).drawsPlainLetterboxBorder(isLetterboxed: true))
        #expect(!TerminalSizingChromeGate(viewportReportPending: true).drawsPlainLetterboxBorder(isLetterboxed: true))
        #expect(!TerminalSizingChromeGate(viewportReportPending: false).drawsPlainLetterboxBorder(isLetterboxed: false))
    }
}
