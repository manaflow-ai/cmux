@testable import CmuxNextActions
import Testing

/// `=~` compiled its pattern on every evaluation (once per candidate binding per key event). The cache
/// compiles each distinct pattern once; results are unchanged.
@Suite struct WhenClauseRegexCacheTests {
    @Test func repeatedEvaluationCompilesOnce() {
        let clause = WhenClause.matches("cacheTestKey", pattern: "^term(inal)?-[0-9]+$")
        let hit = KeyContext(["cacheTestKey": .string("terminal-42")])
        let miss = KeyContext(["cacheTestKey": .string("page")])
        let before = WhenRegexCache.shared.compiled
        for _ in 0..<1000 {
            #expect(clause.evaluate(hit))
            #expect(!clause.evaluate(miss))
        }
        #expect(WhenRegexCache.shared.compiled - before == 1)
    }

    @Test func invalidPatternNeverMatchesAndCompilesOnce() {
        let clause = WhenClause.matches("cacheTestKey", pattern: "([unclosed")
        let context = KeyContext(["cacheTestKey": .string("([unclosed")])
        let before = WhenRegexCache.shared.compiled
        for _ in 0..<50 { #expect(!clause.evaluate(context)) }
        #expect(WhenRegexCache.shared.compiled - before == 1)
    }
}
