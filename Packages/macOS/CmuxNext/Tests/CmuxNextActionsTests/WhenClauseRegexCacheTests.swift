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

/// 10k evaluations of a `=~` clause, timed (the PR's before/after number; printed, never asserted on).
@Suite struct WhenClauseRegexMeasureTests {
    @Test func tenThousandEvaluations() throws {
        let clause = try WhenClause.parse("cacheTestKey =~ /^term(inal)?-[0-9]+$/")
        let hit = KeyContext(["cacheTestKey": .string("terminal-42")])
        var matched = 0
        let start = ContinuousClock.now
        for _ in 0..<10_000 where clause.evaluate(hit) { matched += 1 }
        let elapsed = ContinuousClock.now - start
        print("WHEN_REGEX_10K_EVALUATIONS_MS=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)")
        #expect(matched == 10_000)
    }
}
