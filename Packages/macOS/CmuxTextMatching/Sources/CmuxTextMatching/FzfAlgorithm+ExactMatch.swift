// Ported from fzf, Copyright (c) 2013-2026 Junegunn Choi, MIT License.
// https://github.com/junegunn/fzf/blob/master/src/algo/algo.go

extension FzfAlgorithm {
    /// fzf's `ExactMatchNaive`: the exact substring with the best first-character bonus (`'abc`).
    ///
    /// - Parameters:
    ///   - text: The text to search.
    ///   - pattern: The pattern, already lowercased when `caseSensitive` is false.
    ///   - caseSensitive: Whether case must match.
    ///   - forward: Search from the start (`true`) or from the end.
    ///   - withPositions: Unused; fzf reports only the span for exact matches.
    /// - Returns: The match, or `nil` when there is none.
    public func exactMatchNaive(
        text: String,
        pattern: String,
        caseSensitive: Bool,
        forward: Bool = true,
        withPositions: Bool = true
    ) -> FzfMatchResult? {
        exactMatch(text: text, pattern: pattern, caseSensitive: caseSensitive, forward: forward, boundaryCheck: false)
    }

    /// fzf's `ExactMatchBoundary`: an exact substring that starts and ends on word boundaries (`'abc'`).
    ///
    /// - Parameters:
    ///   - text: The text to search.
    ///   - pattern: The pattern, already lowercased when `caseSensitive` is false.
    ///   - caseSensitive: Whether case must match.
    ///   - forward: Search from the start (`true`) or from the end.
    ///   - withPositions: Unused; fzf reports only the span for exact matches.
    /// - Returns: The match, or `nil` when there is none.
    public func exactMatchBoundary(
        text: String,
        pattern: String,
        caseSensitive: Bool,
        forward: Bool = true,
        withPositions: Bool = true
    ) -> FzfMatchResult? {
        exactMatch(text: text, pattern: pattern, caseSensitive: caseSensitive, forward: forward, boundaryCheck: true)
    }

    /// fzf's `PrefixMatch` (`^abc`), ignoring leading whitespace unless the pattern starts with it.
    ///
    /// - Parameters:
    ///   - text: The text to search.
    ///   - pattern: The pattern, already lowercased when `caseSensitive` is false.
    ///   - caseSensitive: Whether case must match.
    ///   - forward: Unused; a prefix has one position.
    ///   - withPositions: Unused; fzf reports only the span.
    /// - Returns: The match, or `nil` when there is none.
    public func prefixMatch(
        text: String,
        pattern: String,
        caseSensitive: Bool,
        forward: Bool = true,
        withPositions: Bool = true
    ) -> FzfMatchResult? {
        let pattern = Self.scalars(pattern)
        if pattern.isEmpty { return FzfMatchResult(start: 0, end: 0, score: 0, positions: []) }
        let input = Self.scalars(text)
        var trimmed = 0
        if !Self.isSpace(pattern[0]) {
            trimmed = input.prefix { Self.isSpace($0) }.count
        }
        if input.count - trimmed < pattern.count { return nil }
        for (index, patternChar) in pattern.enumerated() {
            let char = caseSensitive ? input[trimmed + index] : Self.lowercasedAny(input[trimmed + index])
            if char != patternChar { return nil }
        }
        let end = trimmed + pattern.count
        let score = calculateScore(
            input: input, pattern: pattern, caseSensitive: caseSensitive, start: trimmed, end: end, withPositions: false
        ).score
        return FzfMatchResult(start: trimmed, end: end, score: score, positions: [])
    }

    /// fzf's `SuffixMatch` (`abc$`), ignoring trailing whitespace unless the pattern ends with it.
    ///
    /// - Parameters:
    ///   - text: The text to search.
    ///   - pattern: The pattern, already lowercased when `caseSensitive` is false.
    ///   - caseSensitive: Whether case must match.
    ///   - forward: Unused; a suffix has one position.
    ///   - withPositions: Unused; fzf reports only the span.
    /// - Returns: The match, or `nil` when there is none.
    public func suffixMatch(
        text: String,
        pattern: String,
        caseSensitive: Bool,
        forward: Bool = true,
        withPositions: Bool = true
    ) -> FzfMatchResult? {
        let pattern = Self.scalars(pattern)
        let input = Self.scalars(text)
        var trimmedLength = input.count
        if pattern.isEmpty || !Self.isSpace(pattern[pattern.count - 1]) {
            trimmedLength -= input.reversed().prefix { Self.isSpace($0) }.count
        }
        if pattern.isEmpty {
            return FzfMatchResult(start: trimmedLength, end: trimmedLength, score: 0, positions: [])
        }
        let difference = trimmedLength - pattern.count
        if difference < 0 { return nil }
        for (index, patternChar) in pattern.enumerated() {
            let char = caseSensitive ? input[index + difference] : Self.lowercasedAny(input[index + difference])
            if char != patternChar { return nil }
        }
        let start = trimmedLength - pattern.count
        let score = calculateScore(
            input: input, pattern: pattern, caseSensitive: caseSensitive, start: start, end: trimmedLength, withPositions: false
        ).score
        return FzfMatchResult(start: start, end: trimmedLength, score: score, positions: [])
    }

    /// fzf's `EqualMatch` (`^abc$`): the whole text, ignoring surrounding whitespace.
    ///
    /// - Parameters:
    ///   - text: The text to compare.
    ///   - pattern: The pattern, already lowercased when `caseSensitive` is false.
    ///   - caseSensitive: Whether case must match.
    ///   - forward: Unused.
    ///   - withPositions: Unused; fzf reports only the span.
    /// - Returns: The match, or `nil` when the text differs.
    public func equalMatch(
        text: String,
        pattern: String,
        caseSensitive: Bool,
        forward: Bool = true,
        withPositions: Bool = true
    ) -> FzfMatchResult? {
        let pattern = Self.scalars(pattern)
        if pattern.isEmpty { return nil }
        let input = Self.scalars(text)
        var trimmed = 0
        if !Self.isSpace(pattern[0]) {
            trimmed = input.prefix { Self.isSpace($0) }.count
        }
        var trimmedEnd = 0
        if !Self.isSpace(pattern[pattern.count - 1]) {
            trimmedEnd = input.reversed().prefix { Self.isSpace($0) }.count
        }
        if input.count - trimmed - trimmedEnd != pattern.count { return nil }
        var middle = String(String.UnicodeScalarView(input[trimmed..<(input.count - trimmedEnd)].compactMap(Unicode.Scalar.init)))
        if !caseSensitive { middle = middle.lowercased() }
        guard Self.scalars(middle) == pattern else { return nil }
        let white = scheme.bonusBoundaryWhite
        let score = (Self.scoreMatch + white) * pattern.count + (Self.bonusFirstCharMultiplier - 1) * white
        return FzfMatchResult(start: trimmed, end: trimmed + pattern.count, score: score, positions: [])
    }

    /// Go's `unicode.ToLower`, which prefix and suffix matching apply to every scalar.
    static func lowercasedAny(_ scalar: UInt32) -> UInt32 {
        lowercased(scalar)
    }

    /// fzf's `bonusAt`.
    func bonus(at index: Int, in input: [UInt32]) -> Int {
        if index == 0 { return scheme.bonusBoundaryWhite }
        return scheme.bonus(previous: scheme.charClass(of: input[index - 1]), current: scheme.charClass(of: input[index]))
    }

    /// fzf's `exactMatchNaive`, with or without the word-boundary check.
    private func exactMatch(
        text: String,
        pattern: String,
        caseSensitive: Bool,
        forward: Bool,
        boundaryCheck: Bool
    ) -> FzfMatchResult? {
        let pattern = Self.scalars(pattern)
        if pattern.isEmpty { return FzfMatchResult(start: 0, end: 0, score: 0, positions: []) }
        let input = Self.scalars(text)
        let inputLength = input.count
        let patternLength = pattern.count
        if inputLength < patternLength { return nil }

        // For simplicity, only look at the bonus at the first character position.
        var patternIndex = 0
        var bestPosition = -1
        var bonus = 0
        var boundaryBonus = 0
        var bestBonus = -1
        var index = 0
        while index < inputLength {
            let textIndex = Self.index(index, count: inputLength, forward: forward)
            let char = Self.folded(input[textIndex], caseSensitive: caseSensitive)
            let patternPosition = Self.index(patternIndex, count: patternLength, forward: forward)
            var ok = pattern[patternPosition] == char
            if ok {
                if patternPosition == 0 {
                    bonus = self.bonus(at: textIndex, in: input)
                }
                if boundaryCheck {
                    if forward && patternPosition == 0 {
                        boundaryBonus = bonus
                    } else if !forward && patternPosition == patternLength - 1 {
                        boundaryBonus = textIndex < inputLength - 1
                            ? self.bonus(at: textIndex + 1, in: input)
                            : scheme.bonusBoundaryWhite
                    }
                    ok = boundaryBonus >= Self.bonusBoundary
                    if ok && patternPosition == 0 {
                        ok = textIndex == 0
                            || scheme.charClass(of: input[textIndex - 1]).rawValue <= FzfCharClass.delimiter.rawValue
                    }
                    if ok && patternPosition == patternLength - 1 {
                        ok = textIndex == inputLength - 1
                            || scheme.charClass(of: input[textIndex + 1]).rawValue <= FzfCharClass.delimiter.rawValue
                    }
                }
            }
            if ok {
                patternIndex += 1
                if patternIndex == patternLength {
                    if bonus > bestBonus {
                        bestPosition = index
                        bestBonus = bonus
                    }
                    if bonus >= Self.bonusBoundary {
                        break
                    }
                    index -= patternIndex - 1
                    patternIndex = 0
                    bonus = 0
                }
            } else {
                index -= patternIndex
                patternIndex = 0
                bonus = 0
            }
            index += 1
        }
        guard bestPosition >= 0 else { return nil }
        let start: Int
        let end: Int
        if forward {
            start = bestPosition - patternLength + 1
            end = bestPosition + 1
        } else {
            start = inputLength - (bestPosition + 1)
            end = inputLength - (bestPosition - patternLength + 1)
        }
        let score: Int
        if boundaryCheck {
            // Underscore boundaries rank lower than the other kinds of boundaries.
            var boundaryScore = bonus
            var deduct = bonus - Self.bonusBoundary + 1
            if start > 0 && input[start - 1] == 0x5F {
                boundaryScore -= deduct + 1
                deduct = 1
            }
            if end < inputLength && input[end] == 0x5F {
                boundaryScore -= deduct
            }
            // Add a base score so this can compete with other match types, e.g. 'foo' | bar.
            score = boundaryScore + Self.scoreMatch * patternLength + scheme.bonusBoundaryWhite * (patternLength + 1)
        } else {
            score = calculateScore(
                input: input, pattern: pattern, caseSensitive: caseSensitive, start: start, end: end, withPositions: false
            ).score
        }
        return FzfMatchResult(start: start, end: end, score: score, positions: [])
    }
}
