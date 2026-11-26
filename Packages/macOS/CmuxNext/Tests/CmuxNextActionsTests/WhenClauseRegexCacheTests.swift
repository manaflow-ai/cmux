import Foundation
@testable import CmuxNextActions
import Testing

/// `=~` compiled its pattern on every evaluation (once per candidate binding per key event). The
/// pattern now compiles once, when the clause is made; results are unchanged.
@Suite struct WhenClauseRegexCacheTests {
    @Test func parsedClauseMatchesWithoutRecompiling() throws {
        let clause = try WhenClause.parse("cacheTestKey =~ /^term(inal)?-[0-9]+$/")
        let hit = KeyContext(["cacheTestKey": .string("terminal-42")])
        let miss = KeyContext(["cacheTestKey": .string("page")])
        // Fails without the change: the clause holds its compiled regex, and every evaluation uses that one.
        guard case .matches(_, let pattern) = clause else { Issue.record("not a =~ clause"); return }
        let compiled = try #require(pattern.regex)
        for _ in 0..<1000 {
            guard case .matches(_, let again) = clause else { return }
            #expect(again.regex === compiled)
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
        print("WHEN_REGEX_10K_AFTER_MS=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)")
        #expect(matched == 10_000)

        // The previous evaluate: compile the pattern on every call (same harness, same pattern and text).
        let text = "terminal-42"
        var oldMatched = 0
        let oldStart = ContinuousClock.now
        for _ in 0..<10_000 {
            guard let regex = try? NSRegularExpression(pattern: "^term(inal)?-[0-9]+$") else { continue }
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { oldMatched += 1 }
        }
        let old = ContinuousClock.now - oldStart
        print("WHEN_REGEX_10K_BEFORE_MS=\(old.components.seconds * 1000 + old.components.attoseconds / 1_000_000_000_000_000)")
        #expect(oldMatched == 10_000)
    }
}
