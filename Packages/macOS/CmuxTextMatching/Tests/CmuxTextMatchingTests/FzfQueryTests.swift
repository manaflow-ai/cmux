// Ports the extended-search cases of fzf's src/pattern_test.go.
// Copyright (c) 2013-2026 Junegunn Choi, MIT License.
@testable import CmuxTextMatching
import Testing

@Suite struct FzfQueryTests {
    /// TestParseTermsExtended: term types, inversion and `|` groups.
    @Test func parsesExtendedTerms() {
        let terms = FzfQuery(
            "aaa 'bbb ^ccc ddd$ !eee !'fff !^ggg !hhh$ | ^iii$ ^xxx | 'yyy | zzz$ | !ZZZ |"
        ).termSets
        guard terms.count == 9 else { Issue.record("expected 9 term sets, got \(terms.count)"); return }
        #expect(terms[0][0].type == .fuzzy && !terms[0][0].inverse)
        #expect(terms[1][0].type == .exact && !terms[1][0].inverse)
        #expect(terms[2][0].type == .prefix && !terms[2][0].inverse)
        #expect(terms[3][0].type == .suffix && !terms[3][0].inverse)
        #expect(terms[4][0].type == .exact && terms[4][0].inverse)
        #expect(terms[5][0].type == .fuzzy && terms[5][0].inverse)
        #expect(terms[6][0].type == .prefix && terms[6][0].inverse)
        #expect(terms[7][0].type == .suffix && terms[7][0].inverse)
        #expect(terms[7][1].type == .equal && !terms[7][1].inverse)
        #expect(terms[8][0].type == .prefix && !terms[8][0].inverse)
        #expect(terms[8][1].type == .exact && !terms[8][1].inverse)
        #expect(terms[8][2].type == .suffix && !terms[8][2].inverse)
        #expect(terms[8][3].type == .exact && terms[8][3].inverse)
        for termSet in terms.prefix(8) {
            #expect(termSet[0].text.count == 3, "\(termSet[0])")
        }
    }

    /// TestParseTermsEmpty: operators with nothing after them are dropped.
    @Test func dropsEmptyTerms() {
        #expect(FzfQuery("' ^ !' !^").isEmpty)
        #expect(FzfQuery("   ").isEmpty)
        #expect(FzfQuery("").match("anything") == FzfQueryMatch(score: 0, positions: []))
    }

    /// TestCaseSensitivity (smart case): a term respects case only if it has an uppercase letter.
    @Test func smartCasePerTerm() {
        let terms = FzfQuery("abc Abc").termSets
        #expect(terms.count == 2)
        #expect(terms.first?.first?.caseSensitive == false)
        #expect(terms.first?.first?.text == "abc")
        #expect(terms.last?.first?.caseSensitive == true)
        #expect(terms.last?.first?.text == "Abc")
        #expect(FzfQuery("abc").match("xAxBxC") != nil)
        #expect(FzfQuery("Abc").match("xaxbxc") == nil)
        #expect(FzfQuery("Abc").match("xAxbxc") != nil)
    }

    /// TestEqual: `^AbC$` matches the whole text, ignoring surrounding whitespace.
    @Test(arguments: [
        ("ABC", false), ("AbC", true), ("AbC  ", true), (" AbC ", true), ("  AbC", true),
    ])
    func equalTerm(text: String, matches: Bool) {
        #expect((FzfQuery("^AbC$").match(text) != nil) == matches)
    }

    /// TestExact: `'abc` finds the exact substring, not the scattered letters.
    @Test func exactTermUsesTheSubstring() {
        let match = FzfQuery("'abc").match("aabbcc abc")
        #expect(match?.positions == [7, 8, 9])
    }

    /// TestOrigTextAndTransformed: `jg` on `junegunn` matches j and the second g.
    @Test func fuzzyPositions() {
        #expect(FzfQuery("jg").match("junegunn")?.positions == [0, 4])
    }

    @Test func escapedSpaceIsPartOfTheTerm() {
        let terms = FzfQuery("foo\\ bar").termSets
        #expect(terms.count == 1)
        #expect(terms.first?.first?.text == "foo bar")
        #expect(FzfQuery("foo\\ bar").match("foo bar") != nil)
        #expect(FzfQuery("foo\\ bar").match("foobar") == nil)
        // A trailing escaped space is kept; a plain trailing space is not.
        #expect(FzfQuery("foo\\ ").termSets.first?.first?.text == "foo ")
        #expect(FzfQuery("foo ").termSets.first?.first?.text == "foo")
    }

    @Test func everyTermSetMustMatch() {
        let query = FzfQuery("srv log")
        #expect(query.match("server-logs") != nil)
        #expect(query.match("server") == nil)
    }

    @Test func orGroupMatchesEitherSide() {
        let query = FzfQuery("^vim | ^emacs")
        #expect(query.match("vim main.c") != nil)
        #expect(query.match("emacs -nw") != nil)
        #expect(query.match("nano") == nil)
    }

    @Test func inverseTermExcludes() {
        let query = FzfQuery("log !test")
        #expect(query.match("build.log") != nil)
        #expect(query.match("test.log") == nil)
        // A query made only of inverse terms matches whatever it doesn't exclude.
        #expect(FzfQuery("!test").match("build.log") != nil)
        #expect(FzfQuery("!test").match("test.log") == nil)
    }

    @Test func prefixAndSuffixAnchors() {
        #expect(FzfQuery("^build").match("build-server") != nil)
        #expect(FzfQuery("^build").match("rebuild") == nil)
        #expect(FzfQuery("log$").match("server.log") != nil)
        #expect(FzfQuery("log$").match("logs") == nil)
    }

    @Test func boundaryExactTerm() {
        #expect(FzfQuery("'log'").match("tail the log now") != nil)
        #expect(FzfQuery("'log'").match("catalogue") == nil)
    }

    @Test func scoreIsTheSumOfTermScores() {
        let algorithm = FzfAlgorithm()
        let a = algorithm.fuzzyMatchV2(text: "foo bar", pattern: "fo", caseSensitive: false)?.score ?? 0
        let b = algorithm.fuzzyMatchV2(text: "foo bar", pattern: "ba", caseSensitive: false)?.score ?? 0
        #expect(FzfQuery("fo ba").match("foo bar")?.score == a + b)
        #expect(FzfQuery("fo ba").match("foo bar")?.positions == [0, 1, 4, 5])
    }

    @Test func betterMatchesScoreHigher() {
        let query = FzfQuery("mw")
        let boundary = query.match("main-window")?.score ?? 0
        let buried = query.match("summwhatever")?.score ?? 0
        #expect(boundary > buried)
    }

    @Test func aCaseModeOverridesSmartCase() {
        #expect(FzfQuery("abc", caseMode: .smart).match("ABC") != nil)
        #expect(FzfQuery("Abc", caseMode: .smart).match("abc") == nil)
        #expect(FzfQuery("abc", caseMode: .respect).match("ABC") == nil)
        #expect(FzfQuery("abc", caseMode: .respect).match("abc") != nil)
        #expect(FzfQuery("ABC", caseMode: .ignore).match("abc") != nil)
        #expect(FzfQuery("'ABC", caseMode: .ignore).match("xabcx") != nil)
    }
}
