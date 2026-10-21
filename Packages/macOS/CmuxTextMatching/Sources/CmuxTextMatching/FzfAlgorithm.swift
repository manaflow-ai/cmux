// Ported from fzf, Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// https://github.com/junegunn/fzf/blob/master/src/algo/algo.go

/// fzf's matching algorithms (`src/algo/algo.go`), ported to Swift.
public struct FzfAlgorithm: Sendable {
    static let scoreMatch = 16
    static let scoreGapStart = -3
    static let scoreGapExtension = -1
    static let bonusBoundary = scoreMatch / 2
    static let bonusNonWord = scoreMatch / 2
    static let bonusCamel123 = bonusBoundary + scoreGapExtension
    static let bonusConsecutive = -(scoreGapStart + scoreGapExtension)
    static let bonusFirstCharMultiplier = 2

    /// The scoring scheme in use.
    public let scheme: FzfScheme

    /// Creates the algorithms for one scheme.
    ///
    /// - Parameter scheme: The scoring scheme; fzf's default unless told otherwise.
    public init(scheme: FzfScheme = .default) {
        self.scheme = scheme
    }

    /// fzf's `FuzzyMatchV2`.
    public func fuzzyMatchV2(text: String, pattern: String, caseSensitive: Bool, forward: Bool = true, withPositions: Bool = true) -> FzfMatchResult? { nil }
    /// fzf's `FuzzyMatchV1`.
    public func fuzzyMatchV1(text: String, pattern: String, caseSensitive: Bool, forward: Bool = true, withPositions: Bool = true) -> FzfMatchResult? { nil }
    /// fzf's `ExactMatchNaive`.
    public func exactMatchNaive(text: String, pattern: String, caseSensitive: Bool, forward: Bool = true, withPositions: Bool = true) -> FzfMatchResult? { nil }
    /// fzf's `ExactMatchBoundary`.
    public func exactMatchBoundary(text: String, pattern: String, caseSensitive: Bool, forward: Bool = true, withPositions: Bool = true) -> FzfMatchResult? { nil }
    /// fzf's `PrefixMatch`.
    public func prefixMatch(text: String, pattern: String, caseSensitive: Bool, forward: Bool = true, withPositions: Bool = true) -> FzfMatchResult? { nil }
    /// fzf's `SuffixMatch`.
    public func suffixMatch(text: String, pattern: String, caseSensitive: Bool, forward: Bool = true, withPositions: Bool = true) -> FzfMatchResult? { nil }
    /// fzf's `EqualMatch`.
    public func equalMatch(text: String, pattern: String, caseSensitive: Bool, forward: Bool = true, withPositions: Bool = true) -> FzfMatchResult? { nil }
}
