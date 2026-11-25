@testable import CmuxNextActions
import Testing

/// `=~` compiled its pattern on every evaluation (once per candidate binding per key event). The cache
/// compiles each distinct pattern once; results are unchanged.
@Suite struct WhenClauseRegexCacheTests {
    @Test func repeatedEvaluationReusesOneCompiledRegex() {
        let pattern = "^term(inal)?-[0-9]+$"
        let first = WhenRegexCache.regex(pattern)
        #expect(first != nil)
        let clause = WhenClause.matches("cacheTestKey", pattern: pattern)
        let hit = KeyContext(["cacheTestKey": .string("terminal-42")])
        let miss = KeyContext(["cacheTestKey": .string("page")])
        for _ in 0..<1000 {
            #expect(clause.evaluate(hit))
            #expect(!clause.evaluate(miss))
        }
        #expect(WhenRegexCache.regex(pattern) === first)
    }

    @Test func invalidPatternNeverMatches() {
        let clause = WhenClause.matches("cacheTestKey", pattern: "([unclosed")
        #expect(!clause.evaluate(KeyContext(["cacheTestKey": .string("([unclosed")])))
    }
}
