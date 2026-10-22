import CmuxTextMatching
import Foundation
import Testing

@Suite struct PaneContentMatcherTests {
    private func found(_ query: String, _ syntax: PaneContentSyntax, _ caseMode: PaneContentCaseMode, in line: String) throws -> String? {
        let matcher = try PaneContentMatcher(query: query, syntax: syntax, caseMode: caseMode)
        return matcher.firstMatch(in: line).map { String(line[$0]) }
    }

    @Test func textIsALiteralSubstring() throws {
        #expect(try found("a.c", .text, .respect, in: "xxabcx a.c") == "a.c")
        #expect(try found("[x]", .text, .respect, in: "list[x] = 1") == "[x]")
        #expect(try found("zzz", .text, .respect, in: "abc") == nil)
    }

    @Test(arguments: PaneContentSyntax.allCases)
    func smartCase(syntax: PaneContentSyntax) throws {
        #expect(try found("error", syntax, .smart, in: "FATAL ERROR here") == "ERROR")
        #expect(try found("Error", syntax, .smart, in: "FATAL ERROR here") == nil)
        #expect(try found("Error", syntax, .smart, in: "an Error here") == "Error")
    }

    @Test(arguments: PaneContentSyntax.allCases)
    func ignoreAndRespect(syntax: PaneContentSyntax) throws {
        #expect(try found("Error", syntax, .ignore, in: "FATAL ERROR") == "ERROR")
        #expect(try found("error", syntax, .respect, in: "FATAL ERROR") == nil)
        #expect(try found("ERROR", syntax, .respect, in: "FATAL ERROR") == "ERROR")
    }

    @Test func globUsesFindWindowSemantics() throws {
        #expect(try found("make*error", .glob, .respect, in: "make: *** error 2") == "make: *** error")
        #expect(try found("v?.[0-9]", .glob, .respect, in: "release v3.7 out") == "v3.7")
        #expect(try found("a.c", .glob, .respect, in: "abc") == nil) // . is literal in a glob
    }

    @Test func regexIsExtended() throws {
        #expect(try found("v[0-9]+\\.[0-9]+", .regex, .respect, in: "tmux v3.7b") == "v3.7")
        #expect(try found("(foo|bar)baz", .regex, .respect, in: "xbarbaz") == "barbaz")
        #expect(try found("^\\$ ", .regex, .respect, in: "$ ls") == "$ ")
    }

    @Test func invalidRegexThrows() {
        #expect(throws: PaneContentMatcherError.self) {
            _ = try PaneContentMatcher(query: "(unclosed", syntax: .regex, caseMode: .smart)
        }
    }

    /// tmux trims trailing whitespace from each line before matching.
    @Test func trailingWhitespaceIsTrimmed() throws {
        #expect(try found("done*", .glob, .respect, in: "done   ") == "done")
        #expect(try found("e +$", .regex, .respect, in: "done   ") == nil)
        #expect(try found("e$", .regex, .respect, in: "done   ") == "e")
    }

    @Test func emptyQuery() throws {
        let matcher = try PaneContentMatcher(query: "", syntax: .text, caseMode: .smart)
        #expect(matcher.isEmpty)
        #expect(matcher.firstMatch(in: "anything") == nil)
        #expect(try !PaneContentMatcher(query: "x", syntax: .glob, caseMode: .smart).isEmpty)
    }

    @Test(arguments: PaneContentSyntax.allCases)
    func everyMatchUpToTheLimit(syntax: PaneContentSyntax) throws {
        let line = "ab ab ab ab"
        let matcher = try PaneContentMatcher(query: "ab", syntax: syntax, caseMode: .respect)
        let ranges = matcher.matches(in: line, limit: 3)
        #expect(ranges.count == 3)
        #expect(ranges.map { line.distance(from: line.startIndex, to: $0.lowerBound) } == [0, 3, 6])
        #expect(ranges.allSatisfy { line[$0] == "ab" })
    }

    @Test func aCancelledSearchStopsARegexThatBacktracks() async throws {
        // `(a+)+$` against 30 a's and a b backtracks for most of a minute. Typing a
        // new query cancels the old search, and the line in progress must stop too.
        let matcher = try PaneContentMatcher(query: "(a+)+$", syntax: .regex, caseMode: .respect)
        let line = String(repeating: "a", count: 30) + "b"
        let (found, elapsed) = await Task.detached { () -> (Bool, Duration) in
            withUnsafeCurrentTask { $0?.cancel() }
            var found = false
            let elapsed = ContinuousClock().measure { found = matcher.firstMatch(in: line) != nil }
            return (found, elapsed)
        }.value
        #expect(!found)
        #expect(elapsed < .seconds(5))
    }
}
