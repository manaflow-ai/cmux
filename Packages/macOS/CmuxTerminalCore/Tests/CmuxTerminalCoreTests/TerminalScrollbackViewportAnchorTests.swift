import CmuxTerminalCore
import GhosttyKit
import Testing

@Suite struct TerminalScrollbackViewportAnchorTests {
    /// Capturing the runtime's last top row produces a semantic live-bottom anchor.
    @Test func capturesLiveBottomSemantically() throws {
        let anchor = try #require(TerminalScrollbackViewportAnchor(
            scrollbar: scrollbar(total: 400, offset: 356, visible: 44)
        ))

        #expect(anchor.rowsBelowViewport == 0)
        #expect(anchor.capturedTotalRows == 400)
    }

    /// A live-bottom anchor resolves to Ghostty's last valid absolute top row.
    @Test func resolvesBottomAnchorToGhosttyTopRow() {
        let anchor = TerminalScrollbackViewportAnchor(
            rowsBelowViewport: 0,
            capturedTotalRows: 400
        )

        #expect(anchor.topRow(in: scrollbar(total: 400, offset: 356, visible: 44)) == 356)
    }

    /// A live-bottom anchor follows the current bottom as new rows arrive.
    @Test func keepsLiveBottomWhenNewRowsArrive() {
        let anchor = TerminalScrollbackViewportAnchor(
            rowsBelowViewport: 0,
            capturedTotalRows: 400
        )

        #expect(anchor.topRow(in: scrollbar(total: 450, offset: 406, visible: 44)) == 406)
    }

    /// An addressable scrollback review anchor remains on its captured output.
    @Test func restoresCapturedScrollbackReviewPositionAfterOutputArrives() {
        let anchor = TerminalScrollbackViewportAnchor(
            rowsBelowViewport: 138,
            capturedTotalRows: 400
        )

        #expect(anchor.topRow(in: scrollbar(total: 450, offset: 406, visible: 44)) == 218)
    }

    /// A historical anchor waits until its captured bottom edge exists.
    @Test func waitsForHistoricalRowsToBecomeAddressable() {
        let anchor = TerminalScrollbackViewportAnchor(
            rowsBelowViewport: 10,
            capturedTotalRows: 400
        )

        #expect(anchor.topRow(in: scrollbar(total: 100, offset: 56, visible: 44)) == nil)
        #expect(anchor.topRow(in: scrollbar(total: 400, offset: 356, visible: 44)) == 346)
    }

    /// Restoration clamps trimmed history and waits for nonzero viewport geometry.
    @Test func clampsToCurrentHistoryAndRequiresVisibleRows() {
        let anchor = TerminalScrollbackViewportAnchor(
            rowsBelowViewport: 0,
            capturedTotalRows: 400
        )

        #expect(anchor.topRow(in: scrollbar(total: 100, offset: 60, visible: 40)) == 60)
        #expect(anchor.topRow(in: scrollbar(total: 100, offset: 100, visible: 0)) == nil)
    }

    /// Builds a runtime scrollbar snapshot for the pure anchor-policy tests.
    private func scrollbar(total: UInt64, offset: UInt64, visible: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(c: ghostty_action_scrollbar_s(total: total, offset: offset, len: visible))
    }
}
