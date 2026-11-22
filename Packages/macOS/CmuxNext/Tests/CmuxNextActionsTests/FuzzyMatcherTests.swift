import CmuxNextActions
import Testing

@Suite struct FuzzyMatcherTests {
    private func score(_ query: String, _ text: String) -> Int? {
        FuzzyMatch.score(query, in: text)
    }

    private func best(_ query: String, among texts: [String]) -> String? {
        texts
            .compactMap { text in score(query, text).map { (text, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    @Test func noMatchIsNil() {
        #expect(score("zzz", "Split Right") == nil)
        #expect(score("rs", "Split") == nil)
        #expect(score("", "anything") == 0)
    }

    @Test func prefixBeatsMidWord() throws {
        let prefix = try #require(score("tab", "Tab Bar"))
        let middle = try #require(score("tab", "Stable Build"))
        #expect(prefix > middle)
    }

    @Test func wordBoundaryBeatsScattered() throws {
        let boundary = try #require(score("sr", "Split Right"))
        let scattered = try #require(score("sr", "Close Tabs to the Right"))
        #expect(boundary > scattered)
    }

    @Test func acronymMatches() {
        #expect(best("nbw", among: ["New Browser Workspace", "New Window", "Enable Browser"]) == "New Browser Workspace")
        #expect(best("tfs", among: ["Toggle Full Screen", "Tab Font Size", "Terminal"]) != nil)
    }

    @Test func consecutiveBeatsGapped() throws {
        let run = try #require(score("side", "Toggle Sidebar"))
        let gapped = try #require(score("side", "Split Window Diff Editor"))
        #expect(run > gapped)
    }

    @Test func exactAndShortWinTies() {
        #expect(best("close tab", among: ["Close Tabs to the Right", "Close Tab", "Close Other Tabs"]) == "Close Tab")
        #expect(best("split down", among: ["Split Browser Down", "Split Down", "Split Right"]) == "Split Down")
    }

    @Test func foldsCaseDiacriticsAndWidth() {
        #expect(score("cafe", "Café Mode") != nil)
        #expect(score("ＡＢＣ", "abc") != nil)
        #expect(score("SPLIT", "split right") != nil)
    }

    @Test func matchesJapanese() {
        #expect(score("タブ", "タブを閉じる") != nil)
        #expect(best("閉じる", among: ["タブを閉じる", "新規タブ"]) == "タブを閉じる")
    }

    @Test func multiTokenRequiresEveryToken() {
        #expect(score("split zz", "Split Right") == nil)
        #expect(score("right split", "Split Right") != nil)
    }

    @Test func weightedFieldsPreferTitle() throws {
        let query = FuzzyQuery("panel")
        let inTitle = try #require(FuzzyMatcher.score(query, fields: [FuzzyField(FuzzyText("Panel Layout"))]))
        let inKeywords = try #require(FuzzyMatcher.score(query, fields: [
            FuzzyField(FuzzyText("Toggle Sidebar")),
            FuzzyField(FuzzyText("panel workspaces"), weight: 80),
        ]))
        #expect(inTitle > inKeywords)
    }

    @Test func matchedPositionsForHighlight() {
        #expect(FuzzyMatcher.matchedPositions(FuzzyQuery("sr"), in: FuzzyText("Split Right")) == [0, 6])
        #expect(FuzzyMatcher.matchedPositions(FuzzyQuery("tab"), in: FuzzyText("Close Tab")) == [6, 7, 8])
    }

    @Test func refinementDetectsTypingForward() {
        #expect(FuzzyQuery("spl").refines(FuzzyQuery("sp")))
        #expect(FuzzyQuery("split r").refines(FuzzyQuery("split")))
        #expect(!FuzzyQuery("sp").refines(FuzzyQuery("spl")))
        #expect(!FuzzyQuery("sx").refines(FuzzyQuery("sp")))
        #expect(!FuzzyQuery("a").refines(FuzzyQuery("")))
    }
}
