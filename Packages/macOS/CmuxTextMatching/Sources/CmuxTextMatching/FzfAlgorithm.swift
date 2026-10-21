// Ported from fzf, Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// https://github.com/junegunn/fzf/blob/master/src/algo/algo.go

/// fzf's matching algorithms (`src/algo/algo.go`), ported to Swift.
///
/// ``fuzzyMatchV2(text:pattern:caseSensitive:forward:withPositions:)`` is fzf's
/// default: a modified Smith-Waterman alignment that finds the highest-scoring
/// occurrence of the pattern, rewarding matches at word starts, after
/// delimiters, at camelCase humps and in consecutive runs, and charging for gaps.
/// The other algorithms back the extended-search operators of ``FzfQuery``.
///
/// As in fzf, every algorithm assumes the caller already lowercased `pattern`
/// when `caseSensitive` is false. Offsets count Unicode scalars. This port skips
/// fzf's ASCII prefilter and scratch-slab reuse, which only affect speed, and
/// does not fold Latin diacritics.
///
/// ```swift
/// let algorithm = FzfAlgorithm()
/// let result = algorithm.fuzzyMatchV2(text: "foo-bar", pattern: "fb", caseSensitive: false)
/// // result?.positions == [0, 4]
/// ```
public struct FzfAlgorithm: Sendable {
    static let scoreMatch = 16
    static let scoreGapStart = -3
    static let scoreGapExtension = -1
    /// Chosen so the bonus is cancelled once the gap between acronym letters grows past 8.
    static let bonusBoundary = scoreMatch / 2
    static let bonusNonWord = scoreMatch / 2
    static let bonusCamel123 = bonusBoundary + scoreGapExtension
    static let bonusConsecutive = -(scoreGapStart + scoreGapExtension)
    static let bonusFirstCharMultiplier = 2
    /// fzf falls back to V1 for longer patterns to keep its 16-bit score matrix safe.
    static let maximumV2PatternLength = 1_000

    /// The scoring scheme in use.
    public let scheme: FzfScheme

    /// Creates the algorithms for one scheme.
    ///
    /// - Parameter scheme: The scoring scheme; fzf's default unless told otherwise.
    public init(scheme: FzfScheme = .default) {
        self.scheme = scheme
    }

    /// fzf's `FuzzyMatchV2`: the best-scoring fuzzy alignment of `pattern` in `text`.
    ///
    /// - Parameters:
    ///   - text: The text to search.
    ///   - pattern: The pattern, already lowercased when `caseSensitive` is false.
    ///   - caseSensitive: Whether uppercase letters in `text` must match exactly.
    ///   - forward: fzf's `--tiebreak` direction; `false` prefers later matches on a tie.
    ///   - withPositions: Whether to backtrack for the matched character offsets.
    /// - Returns: The match, or `nil` when `pattern` is not a subsequence of `text`.
    public func fuzzyMatchV2(
        text: String,
        pattern: String,
        caseSensitive: Bool,
        forward: Bool = true,
        withPositions: Bool = true
    ) -> FzfMatchResult? {
        let pattern = Self.scalars(pattern)
        let patternLength = pattern.count
        if patternLength == 0 {
            return FzfMatchResult(start: 0, end: 0, score: 0, positions: [])
        }
        var input = Self.scalars(text)
        let inputLength = input.count
        if patternLength > inputLength { return nil }
        if patternLength > Self.maximumV2PatternLength {
            return fuzzyMatchV1(
                text: text,
                pattern: String(String.UnicodeScalarView(pattern.compactMap(Unicode.Scalar.init))),
                caseSensitive: caseSensitive,
                forward: forward,
                withPositions: withPositions
            )
        }

        // Phase 2. Calculate the bonus for each point, the first occurrence of each
        // pattern character, and the first row of the score matrix.
        var initialScores = [Int](repeating: 0, count: inputLength)
        var initialConsecutive = [Int](repeating: 0, count: inputLength)
        var bonuses = [Int](repeating: 0, count: inputLength)
        var firstOccurrences = [Int](repeating: 0, count: patternLength)
        var maxScore = 0
        var maxScorePos = 0
        var patternIndex = 0
        var lastIndex = 0
        let firstPatternChar = pattern[0]
        var patternChar = pattern[0]
        var previousInitialScore = 0
        var previousClass = scheme.initialCharClass
        var inGap = false
        for offset in 0..<inputLength {
            var char = input[offset]
            let charClass = scheme.charClass(of: char)
            if !caseSensitive && charClass == .upper {
                char = Self.lowercased(char)
                input[offset] = char
            }
            let bonus = scheme.bonus(previous: previousClass, current: charClass)
            bonuses[offset] = bonus
            previousClass = charClass

            if char == patternChar {
                if patternIndex < patternLength {
                    firstOccurrences[patternIndex] = offset
                    patternIndex += 1
                    patternChar = pattern[min(patternIndex, patternLength - 1)]
                }
                lastIndex = offset
            }

            if char == firstPatternChar {
                let score = Self.scoreMatch + bonus * Self.bonusFirstCharMultiplier
                initialScores[offset] = score
                initialConsecutive[offset] = 1
                if patternLength == 1 && (forward && score > maxScore || !forward && score >= maxScore) {
                    maxScore = score
                    maxScorePos = offset
                    if forward && bonus >= Self.bonusBoundary {
                        break
                    }
                }
                inGap = false
            } else {
                let penalty = inGap ? Self.scoreGapExtension : Self.scoreGapStart
                initialScores[offset] = max(previousInitialScore + penalty, 0)
                initialConsecutive[offset] = 0
                inGap = true
            }
            previousInitialScore = initialScores[offset]
        }
        if patternIndex != patternLength { return nil }
        if patternLength == 1 {
            return FzfMatchResult(
                start: maxScorePos,
                end: maxScorePos + 1,
                score: maxScore,
                positions: withPositions ? [maxScorePos] : []
            )
        }

        // Phase 3. Fill in the score matrix. Unlike the original algorithm,
        // omitting a pattern character is not allowed.
        let firstOffset = firstOccurrences[0]
        let width = lastIndex - firstOffset + 1
        var scores = [Int](repeating: 0, count: width * patternLength)
        var consecutives = [Int](repeating: 0, count: width * patternLength)
        for column in 0..<width {
            scores[column] = initialScores[firstOffset + column]
            consecutives[column] = initialConsecutive[firstOffset + column]
        }
        for row in 1..<patternLength {
            let first = firstOccurrences[row]
            let rowChar = pattern[row]
            let rowStart = row * width
            var rowInGap = false
            scores[rowStart + first - firstOffset - 1] = 0
            for column in first...lastIndex {
                let cell = rowStart + column - firstOffset
                let left = scores[cell - 1]
                let s2 = left + (rowInGap ? Self.scoreGapExtension : Self.scoreGapStart)
                var s1 = 0
                var consecutive = 0
                if rowChar == input[column] {
                    let diagonal = cell - 1 - width
                    s1 = scores[diagonal] + Self.scoreMatch
                    var bonus = bonuses[column]
                    consecutive = consecutives[diagonal] + 1
                    if consecutive > 1 {
                        let chunkBonus = bonuses[column - consecutive + 1]
                        // Break the consecutive chunk.
                        if bonus >= Self.bonusBoundary && bonus > chunkBonus {
                            consecutive = 1
                        } else {
                            bonus = max(bonus, Self.bonusConsecutive, chunkBonus)
                        }
                    }
                    if s1 + bonus < s2 {
                        s1 += bonuses[column]
                        consecutive = 0
                    } else {
                        s1 += bonus
                    }
                }
                consecutives[cell] = consecutive
                rowInGap = s1 < s2
                let score = max(s1, s2, 0)
                if row == patternLength - 1 && (forward && score > maxScore || !forward && score >= maxScore) {
                    maxScore = score
                    maxScorePos = column
                }
                scores[cell] = score
            }
        }

        // Phase 4. Backtrace to find the character positions.
        var positions: [Int] = []
        var column = firstOffset
        if withPositions {
            positions.reserveCapacity(patternLength)
            var row = patternLength - 1
            column = maxScorePos
            var preferMatch = true
            while true {
                let rowStart = row * width
                let offset = column - firstOffset
                let score = scores[rowStart + offset]
                var diagonalScore = 0
                var leftScore = 0
                if row > 0 && column >= firstOccurrences[row] {
                    diagonalScore = scores[rowStart - width + offset - 1]
                }
                if column > firstOccurrences[row] {
                    leftScore = scores[rowStart + offset - 1]
                }
                let currentRow = row
                if score > diagonalScore && (score > leftScore || score == leftScore && preferMatch) {
                    positions.append(column)
                    if row == 0 { break }
                    row -= 1
                }
                // The row below is only written from its first occurrence on.
                preferMatch = consecutives[rowStart + offset] > 1
                    || currentRow + 1 < patternLength
                    && column < lastIndex
                    && column + 1 >= firstOccurrences[currentRow + 1]
                    && consecutives[rowStart + width + offset + 1] > 0
                column -= 1
            }
            positions.reverse()
        }
        return FzfMatchResult(start: column, end: maxScorePos + 1, score: maxScore, positions: positions)
    }

    /// The text as Unicode scalar values, fzf's runes.
    static func scalars(_ text: String) -> [UInt32] {
        text.unicodeScalars.map(\.value)
    }

    /// The simple lowercase mapping of one scalar (fzf's `unicode.To(unicode.LowerCase, r)`).
    static func lowercased(_ scalar: UInt32) -> UInt32 {
        if scalar <= 127 {
            return (0x41...0x5A).contains(scalar) ? scalar + 32 : scalar
        }
        guard let unicodeScalar = Unicode.Scalar(scalar) else { return scalar }
        let mapped = unicodeScalar.properties.lowercaseMapping.unicodeScalars
        guard mapped.count == 1, let only = mapped.first else { return scalar }
        return only.value
    }

    /// fzf's case folding for V1 and the exact matchers: ASCII A-Z, then any non-ASCII scalar.
    static func folded(_ scalar: UInt32, caseSensitive: Bool) -> UInt32 {
        guard !caseSensitive else { return scalar }
        if (0x41...0x5A).contains(scalar) { return scalar + 32 }
        if scalar > 127 { return lowercased(scalar) }
        return scalar
    }

    /// Whether a scalar is whitespace by Go's `unicode.IsSpace`.
    static func isSpace(_ scalar: UInt32) -> Bool {
        Unicode.Scalar(scalar)?.properties.isWhitespace ?? false
    }

    /// fzf's `indexAt`: iterate from the end when not going forward.
    static func index(_ index: Int, count: Int, forward: Bool) -> Int {
        forward ? index : count - index - 1
    }
}
