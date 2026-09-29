import Foundation

/// Text prepared once for repeated fuzzy matching: case and diacritic folded
/// scalars plus a per-position boundary bonus. Build it when the candidate
/// set changes, not per keystroke.
nonisolated public struct FuzzyText: Sendable {
    public let original: String
    /// One folded scalar per scalar of `original`, so match positions map
    /// straight back for highlighting.
    let folded: [UInt32]
    let bonus: [Int32]
    /// Folded scalars at word starts, for acronym matches ("sr" -> "Split Right").
    let initials: [UInt32]

    public init(_ string: String) {
        original = string
        let scalars = Array(string.unicodeScalars)
        var folded: [UInt32] = []
        folded.reserveCapacity(scalars.count)
        var bonus: [Int32] = []
        bonus.reserveCapacity(scalars.count)
        var initials: [UInt32] = []
        var previous: CharClass = .delimiter
        for (index, scalar) in scalars.enumerated() {
            let folding = Self.fold(scalar)
            folded.append(folding)
            let current = CharClass(scalar)
            let b = Self.boundaryBonus(previous: previous, current: current, isFirst: index == 0)
            bonus.append(b)
            if b >= FuzzyMatcher.camelBonus, current != .delimiter, current != .ideograph {
                initials.append(folding)
            }
            previous = current
        }
        self.folded = folded
        self.bonus = bonus
        self.initials = initials
    }

    public var isEmpty: Bool { folded.isEmpty }

    static func fold(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        if value < 0x80 {
            // ASCII fast path.
            if value >= 0x41, value <= 0x5A { return value + 0x20 }
            return value
        }
        let folded = String(Character(scalar)).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        return folded.unicodeScalars.first?.value ?? value
    }

    static func boundaryBonus(previous: CharClass, current: CharClass, isFirst: Bool) -> Int32 {
        if current == .delimiter { return 0 }
        if current == .ideograph { return isFirst ? FuzzyMatcher.startBonus : FuzzyMatcher.ideographBonus }
        if isFirst { return FuzzyMatcher.startBonus }
        switch (previous, current) {
        case (.delimiter, _): return FuzzyMatcher.wordBonus
        case (.lower, .upper): return FuzzyMatcher.camelBonus
        case (.ideograph, _): return FuzzyMatcher.wordBonus
        case (.lower, .digit), (.upper, .digit), (.digit, .lower), (.digit, .upper): return FuzzyMatcher.digitBonus
        default: return 0
        }
    }
}

nonisolated enum CharClass: Equatable {
    case lower, upper, digit, delimiter, ideograph, other

    init(_ scalar: Unicode.Scalar) {
        let v = scalar.value
        switch v {
        case 0x61...0x7A: self = .lower
        case 0x41...0x5A: self = .upper
        case 0x30...0x39: self = .digit
        case 0x20, 0x09, 0x2D, 0x5F, 0x2E, 0x2F, 0x3A, 0x2C, 0x28, 0x29, 0x5B, 0x5D, 0x3C, 0x3E, 0x2026, 0x3001, 0x3002, 0xFF08, 0xFF09:
            self = .delimiter
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF:
            self = .ideograph
        default:
            let props = scalar.properties
            if props.isWhitespace { self = .delimiter }
            else if props.isUppercase { self = .upper }
            else if props.isLowercase { self = .lower }
            else { self = .other }
        }
    }
}

/// A parsed search query. Whitespace separates tokens; every token must match.
nonisolated public struct FuzzyQuery: Sendable, Equatable {
    public let raw: String
    let tokens: [[UInt32]]
    /// All tokens joined without spaces, for acronym and prefix checks.
    let joined: [UInt32]
    /// The folded query with single spaces, for exact and prefix checks.
    let phrase: [UInt32]

    public init(_ string: String) {
        raw = string
        let words = string.split(whereSeparator: { $0.isWhitespace })
        tokens = words.map { $0.unicodeScalars.map(FuzzyText.fold) }
        joined = tokens.flatMap { $0 }
        phrase = Array(words.joined(separator: " ").unicodeScalars.map(FuzzyText.fold))
    }

    public var isEmpty: Bool { tokens.isEmpty }

    /// Whether every match of `self` is also a match of `previous`, so an
    /// incremental search can filter the previous result instead of the
    /// whole candidate set.
    public func refines(_ previous: FuzzyQuery) -> Bool {
        guard !previous.isEmpty, tokens.count >= previous.tokens.count else { return false }
        for (index, token) in previous.tokens.enumerated() {
            let current = tokens[index]
            if index == previous.tokens.count - 1 {
                // The last token may have grown.
                guard current.starts(with: token) else { return false }
            } else if current != token {
                return false
            }
        }
        return true
    }
}

/// One searchable field of a candidate with its weight in percent.
nonisolated public struct FuzzyField: Sendable {
    public let text: FuzzyText
    public let weight: Int32

    public init(_ text: FuzzyText, weight: Int32 = 100) {
        self.text = text
        self.weight = weight
    }
}

/// Subsequence matcher in the spirit of fzf v1: find the shortest window that
/// contains the token, then score each matched character with bonuses for
/// word boundaries, camel case, consecutive runs, and the first character,
/// minus gap penalties. Whole-query bonuses reward exact, prefix, and acronym
/// matches. Linear in text length, no allocation per candidate.
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
        var total: Int32 = 0
        for token in query.tokens {
            var best: Int32 = .min
            for field in fields {
                guard let s = tokenScore(token, in: field.text)?.score else { continue }
                let weighted = s * field.weight / 100
                if weighted > best { best = weighted }
            }
            guard best != .min else { return nil }
            total += best
        }
        var bonus: Int32 = 0
        var shortest = Int32.max
        for field in fields {
            let b = phraseBonus(query, in: field.text) * field.weight / 100
            if b > bonus { bonus = b }
            if field.weight == 100 { shortest = min(shortest, Int32(field.text.folded.count)) }
        }
        // Shorter primary text wins ties ("Close Tab" over "Close Tabs to the Right").
        let lengthPenalty = shortest == .max ? 0 : shortest / 6
        return Int(total + bonus - lengthPenalty)
    }

    /// Positions (scalar offsets into `text.original`) matched by `query`,
    /// for highlighting. Empty when the query does not fully match `text`.
    public static func matchedPositions(_ query: FuzzyQuery, in text: FuzzyText) -> [Int] {
        var positions = Set<Int>()
        let phrase = query.phrase
        if !phrase.isEmpty, let start = substringStart(phrase, in: text, requireBoundary: false) {
            return Array(start..<(start + phrase.count)).filter { text.folded[$0] != 0x20 }
        }
        for token in query.tokens {
            guard let match = tokenScore(token, in: text) else { continue }
            var ti = 0
            for i in match.start...match.end where ti < token.count && text.folded[i] == token[ti] {
                positions.insert(i)
                ti += 1
            }
        }
        return positions.sorted()
    }

    // MARK: - Internals

    struct TokenMatch {
        var score: Int32
        var start: Int
        var end: Int
    }

    static func tokenScore(_ token: [UInt32], in text: FuzzyText) -> TokenMatch? {
        let folded = text.folded
        let m = token.count
        let n = folded.count
        guard m > 0, m <= n else { return m == 0 ? TokenMatch(score: 0, start: 0, end: 0) : nil }

        // Prefer a contiguous hit at a word boundary: it is what people type.
        if let start = substringStart(token, in: text, requireBoundary: true) {
            return TokenMatch(score: windowScore(token, text, start: start, end: start + m - 1), start: start, end: start + m - 1)
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
        var bestScore = windowScore(token, text, start: start, end: end)

        // A second window anchored at the first word-start occurrence of the
        // first token character often scores better ("tab" in "Toggle Tab Bar").
        if text.bonus[start] < wordBonus {
            var j = 0
            while j < n {
                if folded[j] == token[0], text.bonus[j] >= camelBonus, j != start {
                    if let alt = forwardWindow(token, text, from: j) {
                        let s = windowScore(token, text, start: j, end: alt)
                        if s > bestScore {
                            bestScore = s
                            start = j
                            end = alt
                        }
                    }
                    break
                }
                j += 1
            }
        }
        return TokenMatch(score: bestScore, start: start, end: end)
    }

    private static func forwardWindow(_ token: [UInt32], _ text: FuzzyText, from start: Int) -> Int? {
        var ti = 0
        var i = start
        let folded = text.folded
        while i < folded.count {
            if folded[i] == token[ti] {
                ti += 1
                if ti == token.count { return i }
            }
            i += 1
        }
        return nil
    }

    private static func windowScore(_ token: [UInt32], _ text: FuzzyText, start: Int, end: Int) -> Int32 {
        let folded = text.folded
        let bonus = text.bonus
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

    private static func substringStart(_ needle: [UInt32], in text: FuzzyText, requireBoundary: Bool) -> Int? {
        let folded = text.folded
        let m = needle.count
        let n = folded.count
        guard m > 0, m <= n else { return nil }
        var i = 0
        let first = needle[0]
        while i <= n - m {
            if folded[i] == first, !requireBoundary || text.bonus[i] >= camelBonus {
                var k = 1
                while k < m, folded[i + k] == needle[k] { k += 1 }
                if k == m { return i }
            }
            i += 1
        }
        return nil
    }

    private static func phraseBonus(_ query: FuzzyQuery, in text: FuzzyText) -> Int32 {
        let phrase = query.phrase
        let folded = text.folded
        guard !phrase.isEmpty, !folded.isEmpty else { return 0 }
        if phrase == folded { return exactBonus }
        if folded.starts(with: phrase) { return prefixBonus }
        if query.joined.count >= 2, text.initials.starts(with: query.joined) { return acronymBonus }
        if phrase.count >= 2, substringStart(phrase, in: text, requireBoundary: true) != nil { return wordPrefixBonus }
        return 0
    }
}
