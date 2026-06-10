import Testing
@testable import CmuxTmuxControlMode

@Suite("tmux control mode encoder")
struct TmuxControlModeEncoderTests {
    @Test func capturePaneRequestsFullHistoryWithEscapes() {
        #expect(TmuxControlModeEncoder.capturePane(paneID: "%3") == "capture-pane -t %3 -p -e -J -S - -E -")
    }

    @Test func sendKeysEncodesBytesAsHex() {
        #expect(TmuxControlModeEncoder.sendKeys(paneID: "%1", bytes: [0x68, 0x69, 0x0D]) == "send-keys -t %1 -H 68 69 0d")
    }

    @Test func refreshClientUsesColumnsByRows() {
        #expect(TmuxControlModeEncoder.refreshClientSize(TerminalSize(columns: 120, rows: 40)) == "refresh-client -C 120x40")
    }

    @Test func terminalSizeClampsToOne() {
        let size = TerminalSize(columns: 0, rows: -5)
        #expect(size.columns == 1)
        #expect(size.rows == 1)
    }
}
