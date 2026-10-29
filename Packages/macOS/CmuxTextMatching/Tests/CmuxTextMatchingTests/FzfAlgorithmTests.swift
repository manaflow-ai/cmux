// Ports fzf's src/algo/algo_test.go. Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// Expected scores are written as the same expressions the Go test uses, so each
// number can be traced to fzf's constants. TestNormalize is not ported: this port
// does not fold Latin diacritics (fzf's --literal behavior).
@testable import CmuxTextMatching
import Testing

/// The algorithm under test, standing in for the Go test's function values.
private enum Algo {
    case fuzzyV1, fuzzyV2, exactNaive, prefix, suffix

    func run(_ text: String, _ pattern: String, _ caseSensitive: Bool, _ forward: Bool) -> FzfMatchResult? {
        let algorithm = FzfAlgorithm()
        switch self {
        case .fuzzyV1: return algorithm.fuzzyMatchV1(text: text, pattern: pattern, caseSensitive: caseSensitive, forward: forward)
        case .fuzzyV2: return algorithm.fuzzyMatchV2(text: text, pattern: pattern, caseSensitive: caseSensitive, forward: forward)
        case .exactNaive: return algorithm.exactMatchNaive(text: text, pattern: pattern, caseSensitive: caseSensitive, forward: forward)
        case .prefix: return algorithm.prefixMatch(text: text, pattern: pattern, caseSensitive: caseSensitive, forward: forward)
        case .suffix: return algorithm.suffixMatch(text: text, pattern: pattern, caseSensitive: caseSensitive, forward: forward)
        }
    }
}

private let scoreMatch = FzfAlgorithm.scoreMatch
private let scoreGapStart = FzfAlgorithm.scoreGapStart
private let scoreGapExtension = FzfAlgorithm.scoreGapExtension
private let bonusBoundary = FzfAlgorithm.bonusBoundary
private let bonusNonWord = FzfAlgorithm.bonusNonWord
private let bonusCamel123 = FzfAlgorithm.bonusCamel123
private let bonusConsecutive = FzfAlgorithm.bonusConsecutive
private let bonusFirstCharMultiplier = FzfAlgorithm.bonusFirstCharMultiplier
private let bonusBoundaryWhite = FzfScheme.default.bonusBoundaryWhite
private let bonusBoundaryDelimiter = FzfScheme.default.bonusBoundaryDelimiter

private let fuzzyV1 = Algo.fuzzyV1
private let fuzzyV2 = Algo.fuzzyV2
private let exactNaive = Algo.exactNaive
private let prefix = Algo.prefix
private let suffix = Algo.suffix

/// fzf's assertMatch: the pattern is lowercased for case-insensitive calls, and the
/// reported span comes from the positions when the algorithm returns any.
private func assertMatch(
    _ algo: Algo,
    _ caseSensitive: Bool,
    _ forward: Bool,
    _ input: String,
    _ pattern: String,
    _ sidx: Int,
    _ eidx: Int,
    _ score: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let pattern = caseSensitive ? pattern : pattern.lowercased()
    let result = algo.run(input, pattern, caseSensitive, forward)
    let start: Int
    let end: Int
    if let result, !result.positions.isEmpty {
        let sorted = result.positions.sorted()
        start = sorted[0]
        end = sorted[sorted.count - 1] + 1
    } else {
        start = result?.start ?? -1
        end = result?.end ?? -1
    }
    let label = "\(input) / \(pattern) forward=\(forward)"
    #expect(start == sidx, "start \(label)", sourceLocation: sourceLocation)
    #expect(end == eidx, "end \(label)", sourceLocation: sourceLocation)
    #expect((result?.score ?? 0) == score, "score \(label)", sourceLocation: sourceLocation)
}

@Suite struct FzfAlgorithmTests {
    @Test(arguments: [true, false], [true, false])
    func fuzzyMatch(useV2: Bool, forward: Bool) {
        let fn = useV2 ? fuzzyV2 : fuzzyV1
        assertMatch(fn, false, forward, "fooBarbaz1", "oBZ", 2, 9,
                    scoreMatch * 3 + bonusCamel123 + scoreGapStart + scoreGapExtension * 3)
        assertMatch(fn, false, forward, "foo bar baz", "fbb", 0, 9,
                    scoreMatch * 3 + bonusBoundaryWhite * bonusFirstCharMultiplier
                        + bonusBoundaryWhite * 2 + 2 * scoreGapStart + 4 * scoreGapExtension)
        assertMatch(fn, false, forward, "/AutomatorDocument.icns", "rdoc", 9, 13,
                    scoreMatch * 4 + bonusCamel123 + bonusConsecutive * 2)
        assertMatch(fn, false, forward, "/man1/zshcompctl.1", "zshc", 6, 10,
                    scoreMatch * 4 + bonusBoundaryDelimiter * bonusFirstCharMultiplier + bonusBoundaryDelimiter * 3)
        assertMatch(fn, false, forward, "/.oh-my-zsh/cache", "zshc", 8, 13,
                    scoreMatch * 4 + bonusBoundary * bonusFirstCharMultiplier + bonusBoundary * 2
                        + scoreGapStart + bonusBoundaryDelimiter)
        // Non-word character at start of input is treated as a strong boundary
        assertMatch(fn, false, forward, ".vimrc", ".vimrc", 0, 6,
                    scoreMatch * 6 + bonusBoundaryWhite * (bonusFirstCharMultiplier + 5))
        // Non-word character right after a delimiter inherits the delimiter boundary
        assertMatch(fn, false, forward, "/.vimrc", ".vimrc", 1, 7,
                    scoreMatch * 6 + bonusBoundaryDelimiter * (bonusFirstCharMultiplier + 5))
        // Non-word character in the middle of a word stays at bonusNonWord
        assertMatch(fn, false, forward, "a.vimrc", ".vimrc", 1, 7,
                    scoreMatch * 6 + bonusBoundary * (bonusFirstCharMultiplier + 5))
        assertMatch(fn, false, forward, "ab0123 456", "12356", 3, 10,
                    scoreMatch * 5 + bonusConsecutive * 3 + scoreGapStart + scoreGapExtension)
        assertMatch(fn, false, forward, "abc123 456", "12356", 3, 10,
                    scoreMatch * 5 + bonusCamel123 * bonusFirstCharMultiplier + bonusCamel123 * 2
                        + bonusConsecutive + scoreGapStart + scoreGapExtension)
        assertMatch(fn, false, forward, "foo/bar/baz", "fbb", 0, 9,
                    scoreMatch * 3 + bonusBoundaryWhite * bonusFirstCharMultiplier
                        + bonusBoundaryDelimiter * 2 + 2 * scoreGapStart + 4 * scoreGapExtension)
        assertMatch(fn, false, forward, "fooBarBaz", "fbb", 0, 7,
                    scoreMatch * 3 + bonusBoundaryWhite * bonusFirstCharMultiplier
                        + bonusCamel123 * 2 + 2 * scoreGapStart + 2 * scoreGapExtension)
        assertMatch(fn, false, forward, "foo barbaz", "fbb", 0, 8,
                    scoreMatch * 3 + bonusBoundaryWhite * bonusFirstCharMultiplier + bonusBoundaryWhite
                        + scoreGapStart * 2 + scoreGapExtension * 3)
        assertMatch(fn, false, forward, "fooBar Baz", "foob", 0, 4,
                    scoreMatch * 4 + bonusBoundaryWhite * bonusFirstCharMultiplier + bonusBoundaryWhite * 3)
        assertMatch(fn, false, forward, "xFoo-Bar Baz", "foo-b", 1, 6,
                    scoreMatch * 5 + bonusCamel123 * bonusFirstCharMultiplier + bonusCamel123 * 2
                        + bonusNonWord + bonusBoundary)

        assertMatch(fn, true, forward, "fooBarbaz", "oBz", 2, 9,
                    scoreMatch * 3 + bonusCamel123 + scoreGapStart + scoreGapExtension * 3)
        assertMatch(fn, true, forward, "Foo/Bar/Baz", "FBB", 0, 9,
                    scoreMatch * 3 + bonusBoundaryWhite * bonusFirstCharMultiplier + bonusBoundaryDelimiter * 2
                        + scoreGapStart * 2 + scoreGapExtension * 4)
        assertMatch(fn, true, forward, "FooBarBaz", "FBB", 0, 7,
                    scoreMatch * 3 + bonusBoundaryWhite * bonusFirstCharMultiplier + bonusCamel123 * 2
                        + scoreGapStart * 2 + scoreGapExtension * 2)
        assertMatch(fn, true, forward, "FooBar Baz", "FooB", 0, 4,
                    scoreMatch * 4 + bonusBoundaryWhite * bonusFirstCharMultiplier + bonusBoundaryWhite * 2
                        + max(bonusCamel123, bonusBoundaryWhite))

        // Consecutive bonus updated
        assertMatch(fn, true, forward, "foo-bar", "o-ba", 2, 6,
                    scoreMatch * 4 + bonusBoundary * 3)

        // Non-match
        assertMatch(fn, true, forward, "fooBarbaz", "oBZ", -1, -1, 0)
        assertMatch(fn, true, forward, "Foo Bar Baz", "fbb", -1, -1, 0)
        assertMatch(fn, true, forward, "fooBarbaz", "fooBarbazz", -1, -1, 0)
    }

    @Test func fuzzyMatchBackward() {
        assertMatch(fuzzyV1, false, true, "foobar fb", "fb", 0, 4,
                    scoreMatch * 2 + bonusBoundaryWhite * bonusFirstCharMultiplier
                        + scoreGapStart + scoreGapExtension)
        assertMatch(fuzzyV1, false, false, "foobar fb", "fb", 7, 9,
                    scoreMatch * 2 + bonusBoundaryWhite * bonusFirstCharMultiplier + bonusBoundaryWhite)
    }

    @Test(arguments: [true, false])
    func exactMatchNaive(forward: Bool) {
        assertMatch(exactNaive, true, forward, "fooBarbaz", "oBA", -1, -1, 0)
        assertMatch(exactNaive, true, forward, "fooBarbaz", "fooBarbazz", -1, -1, 0)

        assertMatch(exactNaive, false, forward, "fooBarbaz", "oBA", 2, 5,
                    scoreMatch * 3 + bonusCamel123 + bonusConsecutive)
        assertMatch(exactNaive, false, forward, "/AutomatorDocument.icns", "rdoc", 9, 13,
                    scoreMatch * 4 + bonusCamel123 + bonusConsecutive * 2)
        assertMatch(exactNaive, false, forward, "/man1/zshcompctl.1", "zshc", 6, 10,
                    scoreMatch * 4 + bonusBoundaryDelimiter * (bonusFirstCharMultiplier + 3))
        assertMatch(exactNaive, false, forward, "/.oh-my-zsh/cache", "zsh/c", 8, 13,
                    scoreMatch * 5 + bonusBoundary * (bonusFirstCharMultiplier + 3) + bonusBoundaryDelimiter)
    }

    @Test func exactMatchNaiveBackward() {
        assertMatch(exactNaive, false, true, "foobar foob", "oo", 1, 3,
                    scoreMatch * 2 + bonusConsecutive)
        assertMatch(exactNaive, false, false, "foobar foob", "oo", 8, 10,
                    scoreMatch * 2 + bonusConsecutive)
    }

    @Test(arguments: [true, false])
    func prefixMatch(forward: Bool) {
        let score = scoreMatch * 3 + bonusBoundaryWhite * bonusFirstCharMultiplier + bonusBoundaryWhite * 2
        assertMatch(prefix, true, forward, "fooBarbaz", "Foo", -1, -1, 0)
        assertMatch(prefix, false, forward, "fooBarBaz", "baz", -1, -1, 0)
        assertMatch(prefix, false, forward, "fooBarbaz", "Foo", 0, 3, score)
        assertMatch(prefix, false, forward, "foOBarBaZ", "foo", 0, 3, score)
        assertMatch(prefix, false, forward, "f-oBarbaz", "f-o", 0, 3, score)

        assertMatch(prefix, false, forward, " fooBar", "foo", 1, 4, score)
        assertMatch(prefix, false, forward, " fooBar", " fo", 0, 3, score)
        assertMatch(prefix, false, forward, "     fo", "foo", -1, -1, 0)
    }

    @Test(arguments: [true, false])
    func suffixMatch(forward: Bool) {
        assertMatch(suffix, true, forward, "fooBarbaz", "Baz", -1, -1, 0)
        assertMatch(suffix, false, forward, "fooBarbaz", "Foo", -1, -1, 0)

        assertMatch(suffix, false, forward, "fooBarbaz", "baz", 6, 9,
                    scoreMatch * 3 + bonusConsecutive * 2)
        assertMatch(suffix, false, forward, "fooBarBaZ", "baz", 6, 9,
                    (scoreMatch + bonusCamel123) * 3 + bonusCamel123 * (bonusFirstCharMultiplier - 1))

        // Strip trailing white space from the string
        assertMatch(suffix, false, forward, "fooBarbaz ", "baz", 6, 9,
                    scoreMatch * 3 + bonusConsecutive * 2)

        // Only when the pattern doesn't end with a space
        assertMatch(suffix, false, forward, "fooBarbaz ", "baz ", 6, 10,
                    scoreMatch * 4 + bonusConsecutive * 2 + bonusBoundaryWhite)
    }

    @Test(arguments: [true, false])
    func emptyPattern(forward: Bool) {
        assertMatch(fuzzyV1, true, forward, "foobar", "", 0, 0, 0)
        assertMatch(fuzzyV2, true, forward, "foobar", "", 0, 0, 0)
        assertMatch(exactNaive, true, forward, "foobar", "", 0, 0, 0)
        assertMatch(prefix, true, forward, "foobar", "", 0, 0, 0)
        assertMatch(suffix, true, forward, "foobar", "", 6, 6, 0)
    }

    /// From fzf's own comment: "fuzzyfinder" vs "fuzzy-finder" on "ff" prefers the boundary.
    @Test func v2PrefersWordBoundaries() {
        let algorithm = FzfAlgorithm()
        let plain = algorithm.fuzzyMatchV2(text: "fuzzyfinder", pattern: "ff", caseSensitive: false)
        let bounded = algorithm.fuzzyMatchV2(text: "fuzzy-finder", pattern: "ff", caseSensitive: false)
        #expect((bounded?.score ?? 0) > (plain?.score ?? 0))
        #expect(bounded?.positions == [0, 6])
    }

    /// V2 finds the best alignment where V1 takes the first one.
    @Test func v2FindsTheBestAlignmentNotTheFirst() {
        let algorithm = FzfAlgorithm()
        let v2 = algorithm.fuzzyMatchV2(text: "a_____b__c__abc", pattern: "abc", caseSensitive: false)
        #expect(v2?.positions == [12, 13, 14])
        let v1 = algorithm.fuzzyMatchV1(text: "a_____b__c__abc", pattern: "abc", caseSensitive: false)
        #expect((v2?.score ?? 0) >= (v1?.score ?? 0))
    }

    @Test func nonASCIIUppercaseFoldsWhenCaseInsensitive() {
        let algorithm = FzfAlgorithm()
        let result = algorithm.fuzzyMatchV2(text: "ÉCOLE", pattern: "école", caseSensitive: false)
        #expect(result?.positions == [0, 1, 2, 3, 4])
    }

    /// The expressions above move with the constants, so pin a few totals as plain numbers:
    /// a change to any scoring constant shows up here.
    @Test(arguments: [
        ("foo bar baz", "fbb", 78),
        ("/man1/zshcompctl.1", "zshc", 109),
        ("fooBarbaz1", "obz", 49),
        ("foo-bar", "o-ba", 88),
    ])
    func scoresMatchFzfLiteralTotals(text: String, pattern: String, score: Int) {
        let algorithm = FzfAlgorithm()
        #expect(algorithm.fuzzyMatchV2(text: text, pattern: pattern, caseSensitive: false)?.score == score)
        #expect(algorithm.fuzzyMatchV1(text: text, pattern: pattern, caseSensitive: false)?.score == score)
    }

    @Test func schemesDifferInBoundaryBonus() {
        #expect(FzfScheme.default.bonusBoundaryWhite == bonusBoundary + 2)
        #expect(FzfScheme.path.bonusBoundaryWhite == bonusBoundary)
        #expect(FzfScheme.history.bonusBoundaryDelimiter == bonusBoundary)
    }
}
