import Foundation

/// Subsequence matcher in the spirit of fzf v1: find the shortest window that
/// contains the token, then score each matched character with bonuses for
/// word boundaries, camel case, consecutive runs, and the first character,
/// minus gap penalties. Whole-query bonuses reward exact, prefix, acronym,
/// and word-start substring matches.
///
/// The scoring core works on raw buffers. `FuzzyCorpus` feeds it slices of
/// one flat store, so a scan over thousands of candidates does no allocation
/// or reference counting; the convenience entry points here wrap a
/// one-candidate corpus so both paths share one implementation.
nonisolated public enum FuzzyMatcher {
    static let matchScore: Int32 = 16
    static let startBonus: Int32 = 10
    static let wordBonus: Int32 = 9
    static let camelBonus: Int32 = 7
    static let digitBonus: Int32 = 4
    static let ideographBonus: Int32 = 3
    static let consecutiveBonus: Int32 = 5
    static let gapStartPenalty: Int32 = 3
    static let gapExtendPenalty: Int32 = 1
    static let exactBonus: Int32 = 220
    static let prefixBonus: Int32 = 90
    static let acronymBonus: Int32 = 70
    static let wordPrefixBonus: Int32 = 30

    /// Score of `query` against a single text. Nil when some token does not
    /// match. Higher is better.
    public static func score(_ query: FuzzyQuery, in text: FuzzyText) -> Int? {
        score(query, fields: CollectionOfOne(FuzzyField(text)))
    }

    /// Score of `query` against a candidate with several weighted fields
    /// (title, keywords, subtitle). Each token scores against its best field;
    /// whole-query bonuses come from the best field. Nil when a token matches
    /// no field.
    public static func score(_ query: FuzzyQuery, fields: some Collection<FuzzyField>) -> Int? {
        guard !query.isEmpty else { return 0 }
        var corpus = FuzzyCorpus()
        corpus.append(Array(fields))
        return corpus.matches(query, in: CollectionOfOne(0)).first?.score
    }

    /// Positions (scalar offsets into `text.original`) matched by `query`,
    /// for highlighting. Empty when the query does not fully match `text`.
    public static func matchedPositions(_ query: FuzzyQuery, in text: FuzzyText) -> [Int] {
        var corpus = FuzzyCorpus()
        corpus.append([FuzzyField(text)])
        return corpus.matchedPositions(query, candidate: 0)
    }

    // MARK: - Buffer core

    struct TokenMatch {
        var score: Int32
        var start: Int
        var end: Int
    }

    static func tokenScore(
        _ token: UnsafeBufferPointer<UInt32>,
        _ folded: UnsafeBufferPointer<UInt32>,
        _ bonus: UnsafeBufferPointer<Int32>
    ) -> TokenMatch? {
        let m = token.count
        let n = folded.count
        guard m > 0 else { return TokenMatch(score: 0, start: 0, end: 0) }
        guard m <= n else { return nil }

        // Prefer a contiguous hit at a word boundary: it is what people type.
        if let start = substringStart(token, folded, bonus, requireBoundary: true) {
            let end = start + m - 1
            return TokenMatch(score: windowScore(token, folded, bonus, start: start, end: end), start: start, end: end)
        }

        // Forward pass: earliest end of a subsequence match.
        var ti = 0
        var end = -1
        var i = 0
        while i < n {
            if folded[i] == token[ti] {
                ti += 1
                if ti == m { end = i; break }
            }
            i += 1
        }
        guard end >= 0 else { return nil }

        // Backward pass: latest start that still contains the token.
        ti = m - 1
        var start = end
        i = end
        while i >= 0 {
            if folded[i] == token[ti] {
                if ti == 0 { start = i; break }
                ti -= 1
            }
            i -= 1
        }
        var best = windowScore(token, folded, bonus, start: start, end: end)

        // A window anchored at the first word-start occurrence of the first
        // token character often scores better ("tab" in "Toggle Tab Bar").
        if bonus[start] < wordBonus {
            let first = token[0]
            var j = 0
            while j < n {
                if folded[j] == first, bonus[j] >= camelBonus, j != start {
                    if let altEnd = forwardWindowEnd(token, folded, from: j) {
                        let s = windowScore(token, folded, bonus, start: j, end: altEnd)
                        if s > best {
                            best = s
                            start = j
                            end = altEnd
                        }
                    }
                    break
                }
                j += 1
            }
        }
        return TokenMatch(score: best, start: start, end: end)
    }

    static func forwardWindowEnd(_ token: UnsafeBufferPointer<UInt32>, _ folded: UnsafeBufferPointer<UInt32>, from start: Int) -> Int? {
        var ti = 0
        var i = start
        while i < folded.count {
            if folded[i] == token[ti] {
                ti += 1
                if ti == token.count { return i }
            }
            i += 1
        }
        return nil
    }

    static func windowScore(
        _ token: UnsafeBufferPointer<UInt32>,
        _ folded: UnsafeBufferPointer<UInt32>,
        _ bonus: UnsafeBufferPointer<Int32>,
        start: Int,
        end: Int
    ) -> Int32 {
        var score: Int32 = 0
        var ti = 0
        var previousMatch = -2
        var runBonus: Int32 = 0
        var i = start
        while i <= end, ti < token.count {
            if folded[i] == token[ti] {
                var b = bonus[i]
                if i == previousMatch + 1 {
                    // Consecutive characters inherit the bonus of the run start.
                    b = max(b, runBonus)
                    score += consecutiveBonus
                } else {
                    runBonus = b
                }
                if ti == 0 { b *= 2 }
                score += matchScore + b
                previousMatch = i
                ti += 1
            } else {
                score -= (i == previousMatch + 1) ? gapStartPenalty : gapExtendPenalty
            }
            i += 1
        }
        // Small penalty for a late start.
        score -= Int32(min(start, 12))
        return score
    }

    static func substringStart(
        _ needle: UnsafeBufferPointer<UInt32>,
        _ folded: UnsafeBufferPointer<UInt32>,
        _ bonus: UnsafeBufferPointer<Int32>,
        requireBoundary: Bool
    ) -> Int? {
        let m = needle.count
        let n = folded.count
        guard m > 0, m <= n else { return nil }
        let first = needle[0]
        var i = 0
        while i <= n - m {
            if folded[i] == first, !requireBoundary || bonus[i] >= camelBonus {
                var k = 1
                while k < m, folded[i + k] == needle[k] { k += 1 }
                if k == m { return i }
            }
            i += 1
        }
        return nil
    }

    static func hasPrefix(_ buffer: UnsafeBufferPointer<UInt32>, _ prefix: UnsafeBufferPointer<UInt32>) -> Bool {
        guard prefix.count <= buffer.count else { return false }
        var i = 0
        while i < prefix.count {
            if buffer[i] != prefix[i] { return false }
            i += 1
        }
        return true
    }

    /// Whole-query bonus for one field: exact, prefix, acronym, or a
    /// contiguous hit at a word start.
    static func phraseBonus(
        phrase: UnsafeBufferPointer<UInt32>,
        joined: UnsafeBufferPointer<UInt32>,
        folded: UnsafeBufferPointer<UInt32>,
        bonus: UnsafeBufferPointer<Int32>,
        initials: UnsafeBufferPointer<UInt32>
    ) -> Int32 {
        guard !phrase.isEmpty, phrase.count <= folded.count else { return 0 }
        if hasPrefix(folded, phrase) {
            return phrase.count == folded.count ? exactBonus : prefixBonus
        }
        if joined.count >= 2, hasPrefix(initials, joined) { return acronymBonus }
        if phrase.count >= 2, substringStart(phrase, folded, bonus, requireBoundary: true) != nil { return wordPrefixBonus }
        return 0
    }
}
