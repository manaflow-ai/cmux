import Testing

@testable import CmuxMobileDiff

@Suite struct IntralineWordDiffTests {
    private let differ = IntralineWordDiff()

    @Test func pureInsertHighlightsTheInsertedSide() {
        let result = differ.ranges(old: "", new: "hello")
        #expect(result.old.isEmpty)
        #expect(result.new == [DiffCharacterRange(lowerBound: 0, upperBound: 5)])
    }

    @Test func pureDeleteHighlightsTheDeletedSide() {
        let result = differ.ranges(old: "hello", new: "")
        #expect(result.old == [DiffCharacterRange(lowerBound: 0, upperBound: 5)])
        #expect(result.new.isEmpty)
    }

    @Test func midLineChangeKeepsCommonPrefixAndSuffix() {
        let old = "let color = red;"
        let new = "let color = blue;"
        let result = differ.ranges(old: old, new: new)
        #expect(fragments(old, ranges: result.old) == ["red"])
        #expect(fragments(new, ranges: result.new) == ["blue"])
    }

    @Test func multipleChangesRetainLCSWords() {
        let old = "alpha one beta two gamma"
        let new = "alpha 1 beta 2 gamma"
        let result = differ.ranges(old: old, new: new)
        #expect(fragments(old, ranges: result.old).joined().contains("one"))
        #expect(fragments(old, ranges: result.old).joined().contains("two"))
        #expect(fragments(new, ranges: result.new).joined().contains("1"))
        #expect(fragments(new, ranges: result.new).joined().contains("2"))
        #expect(!fragments(old, ranges: result.old).joined().contains("beta"))
    }

    @Test func whitespaceOnlyChangeHighlightsOnlyExtraWhitespace() {
        let result = differ.ranges(old: "alpha beta", new: "alpha  beta")
        #expect(result.old.isEmpty)
        #expect(fragments("alpha  beta", ranges: result.new) == [" "])
    }

    @Test func unicodeRangesUseCharacterOffsets() {
        let emoji = differ.ranges(old: "A😀B", new: "A😎B")
        #expect(emoji.old == [DiffCharacterRange(lowerBound: 1, upperBound: 2)])
        #expect(emoji.new == [DiffCharacterRange(lowerBound: 1, upperBound: 2)])

        let cjk = differ.ranges(old: "設定を開く", new: "設定を閉じる")
        #expect(fragments("設定を開く", ranges: cjk.old) == ["開く"])
        #expect(fragments("設定を閉じる", ranges: cjk.new) == ["閉じる"])
    }

    @Test func lineLengthCapSkipsWork() {
        let capped = IntralineWordDiff(maximumLineLength: 4)
        let result = capped.ranges(old: "12345", new: "12346")
        #expect(result.old.isEmpty)
        #expect(result.new.isEmpty)
    }

    private func fragments(_ text: String, ranges: [DiffCharacterRange]) -> [String] {
        let characters = Array(text)
        return ranges.map { String(characters[$0.lowerBound..<$0.upperBound]) }
    }
}
