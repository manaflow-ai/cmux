@testable import CmuxNextActions
import Testing

/// `=~` compiled its pattern on every evaluation (once per candidate binding per key event). The
/// pattern now compiles once, when the clause is made; results are unchanged.
@Suite struct WhenClauseRegexCacheTests {
    @Test func parsedClauseMatchesWithoutRecompiling() throws {
        let clause = try WhenClause.parse("cacheTestKey =~ /^term(inal)?-[0-9]+$/")
        let hit = KeyContext(["cacheTestKey": .string("terminal-42")])
        let miss = KeyContext(["cacheTestKey": .string("page")])
        for _ in 0..<1000 {
            #expect(clause.evaluate(hit))
            #expect(!clause.evaluate(miss))
        }
    }

    @Test func invalidPatternNeverMatches() {
        let clause = WhenClause.matches("cacheTestKey", pattern: WhenPattern("([unclosed"))
        #expect(!clause.evaluate(KeyContext(["cacheTestKey": .string("([unclosed")])))
    }

    @Test func equalPatternsAreEqual() {
        #expect(WhenPattern("a+") == WhenPattern("a+"))
        #expect(WhenPattern("a+") != WhenPattern("b+"))
    }
}
