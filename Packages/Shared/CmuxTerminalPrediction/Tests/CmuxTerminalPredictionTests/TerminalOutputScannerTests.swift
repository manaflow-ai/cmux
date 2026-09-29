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

    @Test func anEscapeEndsAStringSequenceAndStartsTheNextOne() {
        // Ghostty leaves any string sequence at the first ESC and parses what
        // follows as a new sequence. A scanner still inside the string would
        // miss the echoes, prompts and screen changes ghostty applies.
        #expect(scan("\u{1B}]0;title\u{1B}x more\u{7}") == [
            .disruptive,
            .printable(0x20), .printable(0x6D), .printable(0x6F), .printable(0x72), .printable(0x65),
            .disruptive
        ])
        #expect(scan("\u{1B}_x\u{1B}[31m hi\u{1B}[?1049h") == [
            .ignorable, .printable(0x20), .printable(0x68), .printable(0x69), .alternateScreen(true)
        ])
    }

    @Test func eightBitControlsEndADeviceControlString() {
        // In DCS, APC, PM and SOS, ghostty leaves the string on any C1 byte;
        // 0x9C is the 8-bit string terminator.
        var scanner = TerminalOutputScanner()
        #expect(scanner.scan(Array("\u{1B}Pabc".utf8) + [0x9C, 0x78]) == [.ignorable, .printable(0x78)])
        #expect(scanner.scan(Array("\u{1B}_abc".utf8) + [0x85, 0x78]) == [.disruptive, .printable(0x78)])
    }

    @Test func deviceControlAndApplicationStringsAreIgnorable() {
        // Their payload is printable ASCII that never reaches the grid; read
        // as printed text it would contradict a correct prediction.
        #expect(scan("\u{1B}P+q544e\u{1B}\\") == [.ignorable])
        #expect(scan("\u{1B}_Gf=100,a=T;AAAA\u{1B}\\") == [.ignorable])
        #expect(scan("\u{1B}^private\u{1B}\\") == [.ignorable])
        #expect(scan("\u{1B}Xstart of string\u{1B}\\x") == [.ignorable, .printable(0x78)])
    }

    @Test func belIsPayloadInADeviceControlString() {
        // BEL is payload here, unlike in an OSC.
        #expect(scan("\u{1B}Pq#0;2;0;0;0\u{7}#0!7~\u{1B}\\") == [.ignorable])
        // tmux passthrough doubles each ESC inside its DCS. Ghostty ends the
        // DCS at the first ESC and runs the inner sequence, and so does this.
        #expect(scan("\u{1B}Ptmux;\u{1B}\u{1B}]0;title\u{7}\u{1B}\\") == [.ignorable, .ignorable])
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

    @Test func oneCellEraseHalvesAreReportedForTheEngineToJudge() {
        // A line editor erasing one character moves left, then clears.
        #expect(scan("\u{8}") == [.cursorLeft])
        #expect(scan("\u{1B}[D\u{1B}[1D") == [.cursorLeft, .cursorLeft])
        #expect(scan("\u{1B}[K\u{1B}[0K\u{1B}[P\u{1B}[1P") == [
            .clearAtCursor, .clearAtCursor, .clearAtCursor, .clearAtCursor
        ])
        // Wider counts, other erase modes and selective erase are redraws.
        #expect(scan("\u{1B}[2D\u{1B}[1K\u{1B}[2P\u{1B}[?K") == [
            .disruptive, .disruptive, .disruptive, .disruptive
        ])
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

    @Test func designatingASCIIIsIgnorable() {
        // xterm's sgr0 is `ESC ( B ESC [ m`; shells emit it around the
        // characters they echo, so it must not read as `(` then a printed B.
        #expect(scan("\u{1B}(B\u{1B}[m") == [.ignorable, .ignorable])
        #expect(scan("\u{1B})Bx") == [.ignorable, .printable(0x78)])
        #expect(scan(["\u{1B}(", "B"]) == [.ignorable])
    }

    @Test func designatingAnotherCharacterSetIsDisruptive() {
        // DEC line drawing remaps later printables, so the echo no longer
        // matches the key that was typed.
        #expect(scan("\u{1B}(0x") == [.disruptive, .printable(0x78)])
        #expect(scan("\u{1B}#8x") == [.disruptive, .printable(0x78)])
    }
}
