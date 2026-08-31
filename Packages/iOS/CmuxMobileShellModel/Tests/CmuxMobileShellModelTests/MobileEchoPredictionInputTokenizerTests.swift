import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileEchoPredictionInputTokenizerTests {
    @Test func classifiesPrintableASCII() {
        #expect(MobileEchoPredictionInputTokenizer.tokenize("a") == [.printable("a")])
        #expect(MobileEchoPredictionInputTokenizer.tokenize(" ") == [.printable(" ")])
        #expect(MobileEchoPredictionInputTokenizer.tokenize("~") == [.printable("~")])
        #expect(
            MobileEchoPredictionInputTokenizer.tokenize("ls")
                == [.printable("l"), .printable("s")]
        )
    }

    @Test func classifiesBackspaceAndDelete() {
        #expect(MobileEchoPredictionInputTokenizer.tokenize("\u{7F}") == [.backspace])
        #expect(MobileEchoPredictionInputTokenizer.tokenize("\u{08}") == [.backspace])
    }

    @Test func classifiesLineBreaks() {
        #expect(MobileEchoPredictionInputTokenizer.tokenize("\r") == [.lineBreak])
        #expect(MobileEchoPredictionInputTokenizer.tokenize("\n") == [.lineBreak])
        #expect(MobileEchoPredictionInputTokenizer.tokenize("\r\n") == [.lineBreak])
    }

    @Test func escapeSwallowsChunkRemainder() {
        // Predicting the printable tail of an escape sequence (the `A` of an
        // arrow key) would paint garbage; the whole remainder is control.
        #expect(MobileEchoPredictionInputTokenizer.tokenize("\u{1B}[A") == [.control])
        #expect(
            MobileEchoPredictionInputTokenizer.tokenize("x\u{1B}[3~")
                == [.printable("x"), .control]
        )
    }

    @Test func classifiesControlAndNonASCIIAsControl() {
        #expect(MobileEchoPredictionInputTokenizer.tokenize("\t") == [.control])
        #expect(MobileEchoPredictionInputTokenizer.tokenize("\u{03}") == [.control])
        #expect(MobileEchoPredictionInputTokenizer.tokenize("あ") == [.control])
        #expect(MobileEchoPredictionInputTokenizer.tokenize("🙂") == [.control])
        #expect(MobileEchoPredictionInputTokenizer.tokenize("é") == [.control])
    }

    @Test func mixedChunkKeepsOrder() {
        #expect(
            MobileEchoPredictionInputTokenizer.tokenize("ab\ru")
                == [.printable("a"), .printable("b"), .lineBreak, .printable("u")]
        )
    }
}
