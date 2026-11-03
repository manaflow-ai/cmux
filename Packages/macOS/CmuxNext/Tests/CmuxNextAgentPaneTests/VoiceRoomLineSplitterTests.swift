import CmuxNextDictation
import Testing

@Suite struct VoiceRoomLineSplitterTests {
    @Test func aSentenceGoesOnceTheNextOneStarts() {
        var splitter = VoiceRoomLineSplitter()
        #expect(splitter.feed("Ship the build", level: 0.2).isEmpty)
        #expect(splitter.feed("Ship the build tonight.", level: 0.6).isEmpty)
        #expect(splitter.feed("Ship the build tonight. Then", level: 0.3) == [VoiceRoomLine(kind: .speech, text: "Ship the build tonight.", level: 0.6)])
        #expect(splitter.feed("Ship the build tonight. Then we test", level: 0.1).isEmpty)
        #expect(splitter.finish("Ship the build tonight. Then we test it.") == [VoiceRoomLine(kind: .speech, text: "Then we test it.", level: 0.3)])
    }

    @Test func severalFinishedSentencesGoAsOneLine() {
        var splitter = VoiceRoomLineSplitter()
        #expect(splitter.feed("Yes. Do it! And", level: 0.5).map(\.text) == ["Yes. Do it!"])
    }

    @Test func aLongRunWithNoEndMarkIsCutAtAWord() {
        var splitter = VoiceRoomLineSplitter(longRun: 20)
        let lines = splitter.feed("one two three four five six seven", level: 0.4)
        #expect(lines.map(\.text) == ["one two three four five six"])
        #expect(splitter.finish("one two three four five six seven").map(\.text) == ["seven"])
    }

    @Test func finishStartsOverAndSendsNothingTwice() {
        var splitter = VoiceRoomLineSplitter()
        _ = splitter.feed("Hello there. Bye", level: 0.4)
        #expect(splitter.finish("Hello there. Bye").map(\.text) == ["Bye"])
        #expect(splitter.finish("").isEmpty)
        #expect(splitter.feed("New session. Next", level: 0.4).map(\.text) == ["New session."])
    }

    @Test func chinesePunctuationEndsASentence() {
        var splitter = VoiceRoomLineSplitter()
        #expect(splitter.feed("好的。下一个", level: 0.4).map(\.text) == ["好的。"])
    }
}
