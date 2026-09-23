import Testing
import UIKit
@testable import CmuxMobileTerminal

@Suite("Terminal column report width policy")
@MainActor
struct TerminalColumnReportWidthSelectionTests {
    @Test("preserves overlay width only in compact horizontal space")
    func preservesOverlayWidthOnlyInCompactSpace() {
        #expect(
            GhosttySurfaceView.preservesWidestRenderedWidth(for: .compact)
        )
        #expect(
            !GhosttySurfaceView.preservesWidestRenderedWidth(for: .regular)
        )
        #expect(
            !GhosttySurfaceView.preservesWidestRenderedWidth(for: .unspecified)
        )
    }
}
