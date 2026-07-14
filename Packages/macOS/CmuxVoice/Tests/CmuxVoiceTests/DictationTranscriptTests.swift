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

    @Test func emptyFinalIsIgnored() {
        var transcript = DictationTranscript()
        _ = transcript.apply(.partial("noise"))
        #expect(transcript.apply(.final("")) == nil)
        #expect(transcript.committedText.isEmpty)
        #expect(transcript.volatileText.isEmpty)
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
