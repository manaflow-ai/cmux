import CmuxNextDictation
import Testing

/// An engine that reports its whole transcript so far (Labs > Parakeet Dictation) becomes finals and
/// partials that never type a word twice.
@Suite
struct DictationRunningTranscriptTests {
    @Test func newlyConfirmedWordsBecomeOneFinalAndTheTailAPartial() {
        var running = DictationRunningTranscript()
        #expect(running.update(confirmed: "", volatile: "hello") == [.partial("hello")])
        #expect(running.update(confirmed: "hello", volatile: "wor") == [.final("hello"), .partial("wor")])
        #expect(running.update(confirmed: "hello world", volatile: "how are") == [.final("world"), .partial("how are")])
    }

    @Test func anUnchangedReportEmitsNothing() {
        var running = DictationRunningTranscript()
        _ = running.update(confirmed: "one two", volatile: "three")
        #expect(running.update(confirmed: "one two", volatile: "three").isEmpty)
        #expect(running.update(confirmed: "one  two", volatile: " three ").isEmpty)
    }

    @Test func aRewriteOfCommittedWordsIsNotTypedAgain() {
        var running = DictationRunningTranscript()
        _ = running.update(confirmed: "their going", volatile: "")
        #expect(running.update(confirmed: "they're going home", volatile: "") == [.final("home")])
    }

    @Test func finishCommitsOnlyTheRestAndClearsTheTail() {
        var running = DictationRunningTranscript()
        _ = running.update(confirmed: "send the", volatile: "build")
        #expect(running.finish(text: "send the build now") == .final("build now"))
        var done = DictationRunningTranscript()
        _ = done.update(confirmed: "all of it", volatile: "")
        #expect(done.finish(text: "all of it") == .final(""))
    }
}
