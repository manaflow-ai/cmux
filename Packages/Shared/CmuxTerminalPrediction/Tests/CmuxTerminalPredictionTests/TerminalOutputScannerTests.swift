import Testing
@testable import CmuxTerminalPrediction

private func scan(_ chunks: [String]) -> [TerminalOutputSignal] {
    var scanner = TerminalOutputScanner()
    return chunks.flatMap { scanner.scan(Array($0.utf8)) }
}

private func scan(_ text: String) -> [TerminalOutputSignal] {
    scan([text])
}

struct TerminalOutputScannerTests {
    @Test func printableBytesReportAsThemselves() {
        #expect(scan("ab") == [.printable(0x61), .printable(0x62)])
    }

    @Test func controlBytesMoveTheScreen() {
        #expect(scan("\r\n\u{7}\t") == [.disruptive, .disruptive, .disruptive, .disruptive])
    }

    @Test func styleChangesCarryNoGridContent() {
        #expect(scan("\u{1B}[32m") == [.ignorable])
        #expect(scan("\u{1B}[0;1;38;5;214m") == [.ignorable])
    }

    @Test func operatingSystemCommandsAreIgnorableWithEitherTerminator() {
        #expect(scan("\u{1B}]133;D;0\u{7}") == [.ignorable])
        #expect(scan("\u{1B}]7;file:///home/leo\u{1B}\\") == [.ignorable])
    }

    @Test func anEscapeInsideAnOperatingSystemCommandDoesNotEndItEarly() {
        // Only ESC \ terminates; a bare ESC is still payload.
        #expect(scan("\u{1B}]0;title\u{1B}x more\u{7}") == [.ignorable])
    }

    @Test func alternateScreenModesAreRecognisedInEveryForm() {
        #expect(scan("\u{1B}[?1049h") == [.alternateScreen(true)])
        #expect(scan("\u{1B}[?1049l") == [.alternateScreen(false)])
        #expect(scan("\u{1B}[?47h") == [.alternateScreen(true)])
        #expect(scan("\u{1B}[?1047l") == [.alternateScreen(false)])
    }

    @Test func otherPrivateModeChangesAreDisruptive() {
        // Bracketed paste and mouse reporting change what input means, so the
        // echo stops being predictable.
        #expect(scan("\u{1B}[?2004h") == [.disruptive])
        #expect(scan("\u{1B}[?1002h") == [.disruptive])
    }

    @Test func cursorMotionIsDisruptive() {
        #expect(scan("\u{1B}[3D") == [.disruptive])
        #expect(scan("\u{1B}[2K") == [.disruptive])
        #expect(scan("\u{1B}[H") == [.disruptive])
    }

    @Test func aSequenceSplitAcrossChunksIsStillOneSignal() {
        // libghostty delivers whatever the read returned, so a sequence can
        // arrive a byte at a time. Re-synchronising per chunk would read this
        // as several disruptive events and withdraw a correct prediction.
        #expect(scan(["\u{1B}", "[", "?", "1", "0", "4", "9", "h"]) == [.alternateScreen(true)])
        #expect(scan(["a\u{1B}[3", "2mb"]) == [.printable(0x61), .ignorable, .printable(0x62)])
        #expect(scan(["\u{1B}]133;C\u{1B}", "\\x"]) == [.ignorable, .printable(0x78)])
    }

    @Test func anUnknownEscapeIsDisruptiveAndRecovers() {
        #expect(scan("\u{1B}Mx") == [.disruptive, .printable(0x78)])
    }
}
