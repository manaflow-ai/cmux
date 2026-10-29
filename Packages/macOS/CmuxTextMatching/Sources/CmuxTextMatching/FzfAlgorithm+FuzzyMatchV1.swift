// Ported from fzf, Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// https://github.com/junegunn/fzf/blob/master/src/algo/algo.go

extension FzfAlgorithm {
    /// fzf's `FuzzyMatchV1`: the first fuzzy occurrence, shortened by a backward scan.
    ///
    /// Fast but not optimal; fzf uses it for very long patterns.
    ///
    /// - Parameters:
    ///   - text: The text to search.
    ///   - pattern: The pattern, already lowercased when `caseSensitive` is false.
    ///   - caseSensitive: Whether case must match.
    ///   - forward: Scan from the start (`true`) or from the end.
    ///   - withPositions: Whether to report the matched character offsets.
    /// - Returns: The match, or `nil` when there is none.
    public func fuzzyMatchV1(
        text: String,
        pattern: String,
        caseSensitive: Bool,
        forward: Bool = true,
        withPositions: Bool = true
    ) -> FzfMatchResult? {
        let pattern = Self.scalars(pattern)
        if pattern.isEmpty { return FzfMatchResult(start: 0, end: 0, score: 0, positions: []) }
        let input = Self.scalars(text)
        let inputLength = input.count
        let patternLength = pattern.count
        var patternIndex = 0
        var startIndex = -1
        var endIndex = -1

        for index in 0..<inputLength {
            let char = Self.folded(input[Self.index(index, count: inputLength, forward: forward)], caseSensitive: caseSensitive)
            let patternChar = pattern[Self.index(patternIndex, count: patternLength, forward: forward)]
            if char == patternChar {
                if startIndex < 0 { startIndex = index }
                patternIndex += 1
                if patternIndex == patternLength {
                    endIndex = index + 1
                    break
                }
            }
        }
        guard startIndex >= 0 && endIndex >= 0 else { return nil }

        patternIndex -= 1
        var index = endIndex - 1
        while index >= startIndex {
            let textIndex = Self.index(index, count: inputLength, forward: forward)
            let char = Self.folded(input[textIndex], caseSensitive: caseSensitive)
            let patternChar = pattern[Self.index(patternIndex, count: patternLength, forward: forward)]
            if char == patternChar {
                patternIndex -= 1
                if patternIndex < 0 {
                    startIndex = index
                    break
                }
            }
            index -= 1
        }
        if !forward {
            (startIndex, endIndex) = (inputLength - endIndex, inputLength - startIndex)
        }
        let (score, positions) = calculateScore(
            input: input,
            pattern: pattern,
            caseSensitive: caseSensitive,
            start: startIndex,
            end: endIndex,
            withPositions: withPositions
        )
        return FzfMatchResult(start: startIndex, end: endIndex, score: score, positions: positions)
    }

    /// fzf's `calculateScore`: the score of the greedy match of `pattern` in `input[start..<end]`.
    func calculateScore(
        input: [UInt32],
        pattern: [UInt32],
        caseSensitive: Bool,
        start: Int,
        end: Int,
        withPositions: Bool
    ) -> (score: Int, positions: [Int]) {
        var patternIndex = 0
        var score = 0
        var inGap = false
        var consecutive = 0
        var firstBonus = 0
        var positions: [Int] = []
        var previousClass = scheme.initialCharClass
        if start > 0 {
            previousClass = scheme.charClass(of: input[start - 1])
        }
        for index in start..<end {
            let original = input[index]
            let charClass = scheme.charClass(of: original)
            let char = Self.folded(original, caseSensitive: caseSensitive)
            if patternIndex < pattern.count && char == pattern[patternIndex] {
                if withPositions { positions.append(index) }
                score += Self.scoreMatch
                var bonus = scheme.bonus(previous: previousClass, current: charClass)
                if consecutive == 0 {
                    firstBonus = bonus
                } else {
                    // Break the consecutive chunk.
                    if bonus >= Self.bonusBoundary && bonus > firstBonus {
                        firstBonus = bonus
                    }
                    bonus = max(bonus, firstBonus, Self.bonusConsecutive)
                }
                if patternIndex == 0 {
                    score += bonus * Self.bonusFirstCharMultiplier
                } else {
                    score += bonus
                }
                inGap = false
                consecutive += 1
                patternIndex += 1
            } else {
                score += inGap ? Self.scoreGapExtension : Self.scoreGapStart
                inGap = true
                consecutive = 0
                firstBonus = 0
            }
            previousClass = charClass
        }
        return (score, positions)
    }
}
