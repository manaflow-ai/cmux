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

    @Test func deviceControlAndApplicationStringsAreIgnorable() {
        // Their payload is printable ASCII that never reaches the grid; read
        // as printed text it would contradict a correct prediction.
        #expect(scan("\u{1B}P+q544e\u{1B}\\") == [.ignorable])
        #expect(scan("\u{1B}_Gf=100,a=T;AAAA\u{1B}\\") == [.ignorable])
        #expect(scan("\u{1B}^private\u{1B}\\") == [.ignorable])
        #expect(scan("\u{1B}Xstart of string\u{1B}\\x") == [.ignorable, .printable(0x78)])
    }

    @Test func onlyStringTerminatorEndsADeviceControlString() {
        // BEL is payload here, unlike in an OSC.
        #expect(scan("\u{1B}Pq#0;2;0;0;0\u{7}#0!7~\u{1B}\\") == [.ignorable])
        // tmux passthrough doubles each ESC inside its DCS.
        #expect(scan("\u{1B}Ptmux;\u{1B}\u{1B}]0;title\u{7}\u{1B}\\") == [.ignorable])
    }

    @Test func aDeviceControlStringSplitAcrossChunksIsStillOneSignal() {
        #expect(scan(["\u{1B}_Gi=1;", "AAAA", "\u{1B}", "\\x"]) == [.ignorable, .printable(0x78)])
    }

    @Test func cancelAbortsAStringSequence() {
        #expect(scan("\u{1B}Pabc\u{18}x") == [.disruptive, .printable(0x78)])
        #expect(scan("\u{1B}]0;abc\u{1A}x") == [.disruptive, .printable(0x78)])
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

    @Test func anOverlongControlSequenceStaysBoundedAndClassifies() {
        // The remote controls sequence length; parameters past the cap are
        // dropped, not stored, and must not truncate into a false match.
        let digits = String(repeating: "9", count: 100_000)
        #expect(scan("\u{1B}[?1049\(digits)h") == [.disruptive])
        #expect(scan("\u{1B}[38;2;\(digits)mx") == [.ignorable, .printable(0x78)])
        // The cap resets per sequence.
        #expect(scan("\u{1B}[\(digits)H\u{1B}[?1049h") == [.disruptive, .alternateScreen(true)])
    }

    @Test func anUnknownEscapeIsDisruptiveAndRecovers() {
        #expect(scan("\u{1B}Mx") == [.disruptive, .printable(0x78)])
    }
}
