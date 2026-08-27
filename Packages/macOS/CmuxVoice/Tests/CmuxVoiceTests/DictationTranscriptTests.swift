import Testing

@testable import CmuxVoice

@Suite
struct DictationTranscriptTests {
    @Test func partialUpdatesVolatileTextWithoutCommitting() {
        var transcript = DictationTranscript()
        #expect(transcript.apply(.partial("hel")) == nil)
        #expect(transcript.apply(.partial("hello wor")) == nil)
        #expect(transcript.volatileText == "hello wor")
        #expect(transcript.committedText.isEmpty)
        #expect(transcript.displayText == "hello wor")
    }

    @Test func finalCommitsAndReturnsDelta() {
        var transcript = DictationTranscript()
        _ = transcript.apply(.partial("hell"))
        let delta = transcript.apply(.final("hello"))
        #expect(delta == "hello")
        #expect(transcript.committedText == "hello")
        #expect(transcript.volatileText.isEmpty)
    }

    @Test func secondSegmentGetsSeparatorSpace() {
        var transcript = DictationTranscript()
        _ = transcript.apply(.final("hello"))
        let delta = transcript.apply(.final("world"))
        #expect(delta == " world")
        #expect(transcript.committedText == "hello world")
    }

    @Test func nonSpacingScriptsDoNotGetAsciiSeparators() {
        let segments = [
            ("こんにちは", "世界"),
            ("안녕", "하세요"),
            ("สวัสดี", "ครับ"),
            ("ខ្មែរ", "ភាសា"),
            ("ສະບາຍດີ", "ຄັບ"),
            ("မြန်မာ", "စာ")
        ]

        for (first, second) in segments {
            var transcript = DictationTranscript()
            _ = transcript.apply(.final(first))
            #expect(transcript.apply(.final(second)) == second)
        }
    }

    @Test func punctuationKeepsNaturalBoundaries() {
        var latin = DictationTranscript()
        _ = latin.apply(.final("hello"))
        #expect(latin.apply(.final(",")) == ",")
        #expect(latin.apply(.final("world")) == " world")

        var cjk = DictationTranscript()
        _ = cjk.apply(.final("世界"))
        #expect(cjk.apply(.final("。")) == "。")
        #expect(cjk.apply(.final("次")) == "次")

        var opening = DictationTranscript()
        _ = opening.apply(.final("("))
        #expect(opening.apply(.final("hello")) == "hello")

        var quote = DictationTranscript()
        _ = quote.apply(.final("\""))
        #expect(quote.apply(.final("hello")) == "hello")
    }

    @Test func closingQuotesAndApostrophesKeepWordSpacing() {
        var apostrophe = DictationTranscript()
        _ = apostrophe.apply(.final("James'"))
        #expect(apostrophe.apply(.final("Bond")) == " Bond")

        var quote = DictationTranscript()
        _ = quote.apply(.final("\"hello\""))
        #expect(quote.apply(.final("world")) == " world")
    }

    @Test func noDoubleSeparatorWhenSegmentsAlreadySpaced() {
        var transcript = DictationTranscript()
        _ = transcript.apply(.final("hello "))
        let delta = transcript.apply(.final("world"))
        #expect(delta == "world")
        #expect(transcript.committedText == "hello world")

        var leading = DictationTranscript()
        _ = leading.apply(.final("hello"))
        #expect(leading.apply(.final(" world")) == " world")
    }

    @Test func emptyFinalClearsRevokedPartial() {
        var transcript = DictationTranscript()
        _ = transcript.apply(.partial("noise"))
        #expect(transcript.apply(.final("")) == nil)
        #expect(transcript.committedText.isEmpty)
        #expect(transcript.volatileText.isEmpty)
    }

    @Test func displayTextKeepsOnlyABoundedTail() {
        var transcript = DictationTranscript()
        _ = transcript.apply(.final(String(repeating: "x", count: 1_000)))
        _ = transcript.apply(.partial(String(repeating: "y", count: 1_000)))
        #expect(transcript.committedText.count <= 4_096)
        #expect(transcript.displayText.count <= 512)
        #expect(transcript.displayText.hasSuffix(String(repeating: "y", count: 512)))
    }

    @Test func displayTextJoinsCommittedAndVolatile() {
        var transcript = DictationTranscript()
        _ = transcript.apply(.final("hello"))
        _ = transcript.apply(.partial("world"))
        #expect(transcript.displayText == "hello world")
    }

    @Test func commitTrailingVolatileTextFlushesDanglingPartial() {
        var transcript = DictationTranscript()
        _ = transcript.apply(.final("hello"))
        _ = transcript.apply(.partial("world"))
        let delta = transcript.commitTrailingVolatileText()
        #expect(delta == " world")
        #expect(transcript.committedText == "hello world")
        #expect(transcript.commitTrailingVolatileText() == nil)
    }
}
