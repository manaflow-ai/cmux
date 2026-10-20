import Foundation

/// The Swift fuzzy matcher behind command-palette ranking: token scoring over
/// word segments with exact/prefix/contains/initialism/stitched-prefix and
/// single-edit fallbacks. Pure logic; scores are deterministic for a given
/// query/candidate pair.
///
/// A matcher is a value object bound to one prepared query: construct it with
/// `init(query:)` (or an already-prepared query) and score candidates through
/// the instance methods. The preparation/normalization building blocks remain
/// `static` factories on the value types they produce, per the foundation
/// helper conventions.
public struct CommandPaletteFuzzyMatcher {
    /// The prepared query this matcher scores candidates against.
    public let preparedQuery: PreparedQuery

    /// Prepares `query` for matching.
    public init(query: String) { self.preparedQuery = Self.preparedQuery(query) }

    /// Binds an already-prepared query.
    public init(preparedQuery: PreparedQuery) { self.preparedQuery = preparedQuery }

    /// Scores `candidate` against this matcher's query; nil when it does not
    /// match.
    public func score(candidate: String) -> Int? {
        Self.score(query: preparedQuery.normalizedText, candidate: candidate)
    }

    /// Scores `preparedCandidate` against this matcher's query.
    public func score(preparedCandidate: PreparedCandidateText) -> Int? {
        Self.score(preparedQuery: preparedQuery, preparedCandidate: preparedCandidate)
    }

    /// Candidate character indices matched by this matcher's query.
    public func matchCharacterIndices(in candidate: String) -> Set<Int> {
        Self.matchCharacterIndices(preparedQuery: preparedQuery, candidate: candidate)
    }

    /// Candidate character indices matched against a prepared candidate.
    public func matchCharacterIndices(in preparedCandidate: PreparedCandidateText) -> Set<Int> {
        Self.matchCharacterIndices(preparedQuery: preparedQuery, preparedCandidate: preparedCandidate)
    }

    private static let tokenBoundaryChars: Set<Character> = [" ", "-", "_", "/", ".", ":"]

    /// Half-open `[start, end)` character range of one word in a candidate.
    public struct WordSegment: Hashable, Sendable {
        /// Index of the first character of the word.
        public let start: Int
        /// Index one past the last character of the word.
        public let end: Int
    }

    /// 128-bit presence mask of ASCII scalars used to cheaply prune
    /// candidates that cannot contain a token's characters.
    public struct ASCIIScalarMask: Equatable, Sendable {
        /// Bits for scalars 0-63.
        public let low: UInt64
        /// Bits for scalars 64-127.
        public let high: UInt64

        /// Creates a mask from raw bit halves.
        public init(low: UInt64, high: UInt64) {
            self.low = low
            self.high = high
        }

        /// Builds the mask from the ASCII scalars of `text`.
        public init(_ text: String) {
            var low: UInt64 = 0
            var high: UInt64 = 0
            for scalar in text.unicodeScalars where scalar.isASCII {
                let value = Int(scalar.value)
                if value < 64 {
                    low |= UInt64(1) << UInt64(value)
                } else {
                    high |= UInt64(1) << UInt64(value - 64)
                }
            }
            self.low = low
            self.high = high
        }

        /// Number of scalars present here but absent from `candidate`.
        public func missingBitCount(from candidate: ASCIIScalarMask) -> Int {
            (low & ~candidate.low).nonzeroBitCount + (high & ~candidate.high).nonzeroBitCount
        }
    }

    /// One normalized query token with precomputed characters, ASCII mask,
    /// and score bounds.
    public struct PreparedToken: Equatable, Sendable {
        /// The normalized token text.
        public let normalizedText: String
        /// The token's characters in order.
        public let characters: [Character]
        /// ASCII presence mask for fast pruning.
        public let asciiMask: ASCIIScalarMask
        /// Whether single-edit (typo) fallback matching applies (length >= 4).
        public let allowsSingleEdit: Bool
        /// Whether the token contains a word-boundary character.
        public let containsTokenBoundaryCharacter: Bool
        /// Maximum achievable score for this token.
        public let scoreUpperBound: Int
        /// Maximum achievable score excluding an exact whole-text match.
        public let scoreUpperBoundWithoutExactMatch: Int

        /// Prepares a normalized token for matching.
        public init(_ normalizedText: String) {
            self.normalizedText = normalizedText
            self.characters = Array(normalizedText)
            self.asciiMask = ASCIIScalarMask(normalizedText)
            self.allowsSingleEdit = characters.count >= 4
            self.containsTokenBoundaryCharacter = characters.contains {
                CommandPaletteFuzzyMatcher.tokenBoundaryChars.contains($0)
            }
            self.scoreUpperBound = max(8000, 3500 + (characters.count * 300))
            self.scoreUpperBoundWithoutExactMatch = max(6799, 3500 + (characters.count * 300))
        }

        /// Fast pre-check: whether `candidate` could possibly match this token
        /// within the allowed edit budget.
        public func couldMatch(_ candidate: PreparedCandidateText) -> Bool {
            let missingCharacters = asciiMask.missingBitCount(from: candidate.asciiMask)
            return missingCharacters <= (allowsSingleEdit ? 1 : 0)
        }
    }

    /// One normalized candidate string with precomputed characters, word
    /// segments, and ASCII mask.
    public struct PreparedCandidateText: Sendable {
        /// The normalized candidate text.
        public let normalizedText: String
        /// The candidate's characters in order.
        public let characters: [Character]
        /// Word segments split on token-boundary characters.
        public let wordSegments: [WordSegment]
        /// ASCII presence mask for fast pruning.
        public let asciiMask: ASCIIScalarMask

        /// Prepares a normalized candidate for matching.
        public init(normalizedText: String) {
            self.normalizedText = normalizedText
            self.characters = Array(normalizedText)
            self.wordSegments = CommandPaletteFuzzyMatcher.wordSegments(characters)
            self.asciiMask = ASCIIScalarMask(normalizedText)
        }
    }

    private enum SingleEditWordPrefixEditKind {
        case candidateExtraCharacter
        case tokenExtraCharacter
        case substitutedCharacter
        case transposedCharacters

        var basePenalty: Int {
            switch self {
            case .candidateExtraCharacter:
                return 0
            case .tokenExtraCharacter:
                return 240
            case .transposedCharacters:
                return 24
            case .substitutedCharacter:
                return 40
            }
        }
    }

    private struct SingleEditWordPrefixMatch {
        let matchedIndices: Set<Int>
        let segmentStart: Int
        let segmentLength: Int
        let prefixLength: Int
        let editPosition: Int
        let editKind: SingleEditWordPrefixEditKind
    }

    /// A normalized query split into prepared tokens.
    public struct PreparedQuery {
        /// The full normalized query text.
        public let normalizedText: String
        /// Normalized query tokens joined by single spaces.
        public let normalizedTokenText: String
        /// The prepared tokens, in query order.
        public let tokens: [PreparedToken]

        /// Whether the query has no tokens.
        public var isEmpty: Bool {
            tokens.isEmpty
        }
    }

    /// Normalizes and tokenizes `query` for matching.
    public static func preparedQuery(_ query: String) -> PreparedQuery {
        let normalizedQuery = normalizeForSearch(query)
        let tokens = normalizedQuery
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map(PreparedToken.init)
        return PreparedQuery(
            normalizedText: normalizedQuery,
            normalizedTokenText: tokens.map(\.normalizedText).joined(separator: " "),
            tokens: tokens
        )
    }

    /// Canonical search normalization: trim, diacritic-fold, case-fold.
    public static func normalizeForSearch(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    /// Normalizes and prepares `candidate`, or nil when it normalizes to empty.
    public static func prepareCandidateText(_ candidate: String) -> PreparedCandidateText? {
        let normalizedCandidate = normalizeForSearch(candidate)
        guard !normalizedCandidate.isEmpty else { return nil }
        return PreparedCandidateText(normalizedText: normalizedCandidate)
    }

    /// Prepares an already-normalized candidate, or nil when empty.
    public static func prepareNormalizedCandidateText(_ normalizedCandidate: String) -> PreparedCandidateText? {
        guard !normalizedCandidate.isEmpty else { return nil }
        return PreparedCandidateText(normalizedText: normalizedCandidate)
    }

    /// Scores `query` against a single candidate; nil when it does not match.
    public static func score(query: String, candidate: String) -> Int? {
        score(query: query, candidates: [candidate])
    }

    /// Scores `query` against multiple candidate texts; nil when any token fails.
    public static func score(query: String, candidates: [String]) -> Int? {
        let preparedQuery = preparedQuery(query)
        var normalizedCandidates: [String] = []
        normalizedCandidates.reserveCapacity(candidates.count)
        for candidate in candidates {
            let normalizedCandidate = normalizeForSearch(candidate)
            guard !normalizedCandidate.isEmpty else { continue }
            normalizedCandidates.append(normalizedCandidate)
        }
        return score(
            preparedQuery: preparedQuery,
            normalizedCandidates: normalizedCandidates
        )
    }

    /// Scores a prepared query against normalized candidate texts.
    public static func score(preparedQuery: PreparedQuery, normalizedCandidates: [String]) -> Int? {
        score(
            preparedQuery: preparedQuery,
            preparedCandidates: normalizedCandidates.compactMap(prepareNormalizedCandidateText),
            exactCandidateTexts: Set(normalizedCandidates)
        )
    }

    /// Scores a prepared query against prepared candidates.
    public static func score(preparedQuery: PreparedQuery, preparedCandidates: [PreparedCandidateText]) -> Int? {
        score(
            preparedQuery: preparedQuery,
            preparedCandidates: preparedCandidates,
            exactCandidateTexts: nil
        )
    }

    /// Scores a prepared query against one prepared candidate.
    public static func score(preparedQuery: PreparedQuery, preparedCandidate: PreparedCandidateText) -> Int? {
        guard !preparedQuery.isEmpty else { return 0 }

        var totalScore = 0
        for token in preparedQuery.tokens {
            guard token.couldMatch(preparedCandidate) else { return nil }
            guard let tokenScore = scoreToken(token, in: preparedCandidate) else { return nil }
            totalScore += tokenScore
        }
        return totalScore
    }

    /// Full scoring entry point with exact-text and prefix-score fast paths.
    public static func score(
        preparedQuery: PreparedQuery,
        preparedCandidates: [PreparedCandidateText],
        exactCandidateTexts: Set<String>?,
        wholeCandidatePrefixScoreByToken: [String: Int]? = nil
    ) -> Int? {
        guard !preparedQuery.isEmpty else { return 0 }
        guard !preparedCandidates.isEmpty else { return nil }

        var totalScore = 0
        for token in preparedQuery.tokens {
            let hasExactCandidateText = exactCandidateTexts?.contains(token.normalizedText) == true
            if token.scoreUpperBound == 8000, hasExactCandidateText {
                totalScore += 8000
                continue
            }
            if exactCandidateTexts != nil,
               !hasExactCandidateText,
               let prefixScore = wholeCandidatePrefixScoreByToken?[token.normalizedText]
                    ?? bestWholeCandidatePrefixScore(token: token, preparedCandidates: preparedCandidates),
               prefixScore >= token.scoreUpperBoundWithoutExactMatch {
                totalScore += prefixScore
                continue
            }

            var bestTokenScore: Int?
            for candidate in preparedCandidates {
                guard token.couldMatch(candidate) else { continue }
                guard let candidateScore = scoreToken(token, in: candidate) else { continue }
                bestTokenScore = max(bestTokenScore ?? candidateScore, candidateScore)
                if bestTokenScore ?? 0 >= token.scoreUpperBound {
                    break
                }
            }
            guard let bestTokenScore else { return nil }
            totalScore += bestTokenScore
        }
        return totalScore
    }

    private static func bestWholeCandidatePrefixScore(
        token: PreparedToken,
        preparedCandidates: [PreparedCandidateText]
    ) -> Int? {
        var bestScore: Int?
        for candidate in preparedCandidates where candidate.normalizedText.hasPrefix(token.normalizedText) {
            let score = 6800 - max(0, candidate.characters.count - token.characters.count)
            bestScore = max(bestScore ?? score, score)
        }
        return bestScore
    }

    /// Precomputes best whole-candidate prefix scores keyed by prefix text.
    public static func wholeCandidatePrefixScoreByToken(
        preparedCandidates: [PreparedCandidateText],
        maxPrefixLength: Int = 16
    ) -> [String: Int] {
        var scores: [String: Int] = [:]
        for candidate in preparedCandidates {
            let prefixLimit = min(candidate.characters.count, maxPrefixLength)
            guard prefixLimit > 0 else { continue }

            for prefixLength in 1...prefixLimit {
                let prefix = String(candidate.characters.prefix(prefixLength))
                let score = 6800 - max(0, candidate.characters.count - prefixLength)
                if score > (scores[prefix] ?? Int.min) {
                    scores[prefix] = score
                }
            }
        }
        return scores
    }

    /// Candidate character indices matched by `query`, for highlight rendering.
    public static func matchCharacterIndices(query: String, candidate: String) -> Set<Int> {
        matchCharacterIndices(preparedQuery: preparedQuery(query), candidate: candidate)
    }

    /// Candidate character indices matched by a prepared query.
    public static func matchCharacterIndices(preparedQuery: PreparedQuery, candidate: String) -> Set<Int> {
        guard !preparedQuery.isEmpty else { return [] }

        guard let preparedCandidate = prepareCandidateText(candidate) else { return [] }
        return matchCharacterIndices(preparedQuery: preparedQuery, preparedCandidate: preparedCandidate)
    }

    /// Candidate character indices matched by a prepared query against a
    /// prepared candidate.
    public static func matchCharacterIndices(
        preparedQuery: PreparedQuery,
        preparedCandidate: PreparedCandidateText
    ) -> Set<Int> {
        guard !preparedQuery.isEmpty else { return [] }

        let loweredCandidate = preparedCandidate.normalizedText
        let candidateChars = preparedCandidate.characters
        var matched: Set<Int> = []

        for token in preparedQuery.tokens {
            guard token.couldMatch(preparedCandidate) else { continue }

            if token.normalizedText == loweredCandidate {
                matched.formUnion(0..<candidateChars.count)
                continue
            }

            if loweredCandidate.hasPrefix(token.normalizedText) {
                matched.formUnion(0..<min(token.characters.count, candidateChars.count))
                continue
            }

            if let range = loweredCandidate.range(of: token.normalizedText) {
                let start = loweredCandidate.distance(from: loweredCandidate.startIndex, to: range.lowerBound)
                let end = min(candidateChars.count, start + token.characters.count)
                matched.formUnion(start..<end)
                continue
            }

            if token.containsTokenBoundaryCharacter {
                guard token.characters.count <= 3 else { continue }
                if let subsequence = subsequenceMatchIndices(token: token, candidate: preparedCandidate) {
                    matched.formUnion(subsequence)
                }
                continue
            }

            if let initialism = initialismMatchIndices(token: token, candidate: preparedCandidate) {
                matched.formUnion(initialism)
                continue
            }

            if let stitched = stitchedWordPrefixMatchIndices(token: token, candidate: preparedCandidate) {
                matched.formUnion(stitched)
                continue
            }

            if let singleEditPrefix = singleEditWordPrefixMatch(
                tokenChars: token.characters,
                candidateChars: candidateChars,
                segments: preparedCandidate.wordSegments
            ) {
                matched.formUnion(singleEditPrefix.matchedIndices)
                continue
            }

            guard token.characters.count <= 3 else { continue }
            if let subsequence = subsequenceMatchIndices(token: token, candidate: preparedCandidate) {
                matched.formUnion(subsequence)
            }
        }

        return matched
    }

    /// Whether `token` matches `candidate` through any non-typo strategy.
    public static func tokenCanMatchWithoutSingleEdit(
        _ token: PreparedToken,
        preparedCandidate candidate: PreparedCandidateText
    ) -> Bool {
        guard !token.normalizedText.isEmpty else { return true }

        let candidateText = candidate.normalizedText
        if token.normalizedText == candidateText {
            return true
        }
        if candidateText.hasPrefix(token.normalizedText) {
            return true
        }
        if candidateText.range(of: token.normalizedText) != nil {
            return true
        }

        guard !token.containsTokenBoundaryCharacter else {
            return token.characters.count <= 3 && subsequenceScore(token: token, candidate: candidate) != nil
        }

        if bestWordScore(tokenChars: token.characters, candidate: candidate) != nil {
            return true
        }
        if initialismScore(tokenChars: token.characters, candidate: candidate) != nil {
            return true
        }
        if stitchedWordPrefixScore(tokenChars: token.characters, candidate: candidate) != nil {
            return true
        }
        if token.characters.count <= 3, subsequenceScore(token: token, candidate: candidate) != nil {
            return true
        }
        return false
    }

    /// Whether any token only matches these candidates via the single-edit
    /// (typo) word-prefix fallback.
    public static func usesSingleEditWordPrefix(
        preparedQuery: PreparedQuery,
        preparedCandidates: [PreparedCandidateText]
    ) -> Bool {
        for token in preparedQuery.tokens where token.allowsSingleEdit && !token.containsTokenBoundaryCharacter {
            for candidate in preparedCandidates {
                guard !tokenCanMatchWithoutSingleEdit(token, preparedCandidate: candidate) else { continue }
                if singleEditWordPrefixMatch(
                    tokenChars: token.characters,
                    candidateChars: candidate.characters,
                    segments: candidate.wordSegments
                ) != nil {
                    return true
                }
            }
        }
        return false
    }

    private static func scoreToken(_ token: PreparedToken, in candidate: PreparedCandidateText) -> Int? {
        guard !token.normalizedText.isEmpty else { return 0 }

        let candidateText = candidate.normalizedText
        let candidateChars = candidate.characters
        let tokenChars = token.characters
        guard tokenChars.count <= candidateChars.count else { return nil }

        if token.normalizedText == candidateText {
            return 8000
        }
        if candidateText.hasPrefix(token.normalizedText) {
            return 6800 - max(0, candidateChars.count - tokenChars.count)
        }

        var bestScore: Int?
        if !token.containsTokenBoundaryCharacter {
            if let wordScore = bestWordScore(tokenChars: tokenChars, candidate: candidate) {
                bestScore = max(bestScore ?? wordScore, wordScore)
            }
            if let singleEditPrefixScore = singleEditWordPrefixScore(
                tokenChars: tokenChars,
                candidate: candidate
            ) {
                bestScore = max(bestScore ?? singleEditPrefixScore, singleEditPrefixScore)
            }
        }

        if let range = candidateText.range(of: token.normalizedText) {
            let distance = candidateText.distance(from: candidateText.startIndex, to: range.lowerBound)
            let lengthPenalty = max(0, candidateChars.count - tokenChars.count)
            let boundaryBoost: Int = {
                guard distance > 0 else { return 220 }
                let prior = candidateChars[distance - 1]
                return tokenBoundaryChars.contains(prior) ? 180 : 0
            }()
            let containsScore = 4200 + boundaryBoost - (distance * 9) - lengthPenalty
            bestScore = max(bestScore ?? containsScore, containsScore)
        }

        if !token.containsTokenBoundaryCharacter {
            if let initialismScore = initialismScore(tokenChars: tokenChars, candidate: candidate) {
                bestScore = max(bestScore ?? initialismScore, initialismScore)
            }

            if let stitchedScore = stitchedWordPrefixScore(tokenChars: tokenChars, candidate: candidate) {
                bestScore = max(bestScore ?? stitchedScore, stitchedScore)
            }
        }

        if tokenChars.count <= 3, let subsequence = subsequenceScore(token: token, candidate: candidate) {
            bestScore = max(bestScore ?? subsequence, subsequence)
        }

        guard let bestScore else { return nil }
        return max(1, bestScore)
    }

    private static func bestWordScore(
        tokenChars: [Character],
        candidate: PreparedCandidateText
    ) -> Int? {
        guard !tokenChars.isEmpty else { return nil }

        let candidateChars = candidate.characters
        var best: Int?
        for segment in candidate.wordSegments {
            let wordLength = segment.end - segment.start
            guard tokenChars.count <= wordLength else { continue }

            var matchesPrefix = true
            for offset in 0..<tokenChars.count where candidateChars[segment.start + offset] != tokenChars[offset] {
                matchesPrefix = false
                break
            }
            guard matchesPrefix else { continue }

            let lengthPenalty = max(0, wordLength - tokenChars.count) * 6
            let distancePenalty = segment.start * 8
            let trailingPenalty = max(0, candidateChars.count - wordLength)
            let prefixScore = 5600 - distancePenalty - lengthPenalty - trailingPenalty
            best = max(best ?? prefixScore, prefixScore)
            if tokenChars.count == wordLength {
                let exactScore = 6200 - distancePenalty - trailingPenalty
                best = max(best ?? exactScore, exactScore)
            }
        }

        return best
    }

    private static func singleEditWordPrefixScore(
        tokenChars: [Character],
        candidate: PreparedCandidateText
    ) -> Int? {
        guard let match = singleEditWordPrefixMatch(
            tokenChars: tokenChars,
            candidateChars: candidate.characters,
            segments: candidate.wordSegments
        ) else {
            return nil
        }
        return singleEditWordPrefixScore(match: match, candidateLength: candidate.characters.count)
    }

    private static func singleEditWordPrefixScore(
        match: SingleEditWordPrefixMatch,
        candidateLength: Int
    ) -> Int {
        let lengthPenalty = max(0, match.segmentLength - match.prefixLength) * 6
        let distancePenalty = match.segmentStart * 8
        let trailingPenalty = max(0, candidateLength - match.segmentLength)
        let editPositionPenalty = max(0, match.editPosition - match.segmentStart) * 10
        return 5000
            - match.editKind.basePenalty
            - distancePenalty
            - lengthPenalty
            - trailingPenalty
            - editPositionPenalty
    }

    private static func initialismScore(tokenChars: [Character], candidate: PreparedCandidateText) -> Int? {
        guard !tokenChars.isEmpty else { return nil }
        let candidateChars = candidate.characters
        let segments = candidate.wordSegments
        guard tokenChars.count <= segments.count else { return nil }

        var matchedStarts: [Int] = []
        var searchWordIndex = 0

        for tokenChar in tokenChars {
            var found = false
            while searchWordIndex < segments.count {
                let segment = segments[searchWordIndex]
                searchWordIndex += 1
                if candidateChars[segment.start] == tokenChar {
                    matchedStarts.append(segment.start)
                    found = true
                    break
                }
            }
            if !found { return nil }
        }

        let firstStart = matchedStarts.first ?? 0
        let skippedWords = max(0, segments.count - tokenChars.count)
        return 3000 + (tokenChars.count * 160) - (firstStart * 5) - (skippedWords * 30)
    }

    private static func tokenPrefixMatches(
        tokenChars: [Character],
        tokenStart: Int,
        length: Int,
        candidateChars: [Character],
        candidateStart: Int
    ) -> Bool {
        guard length >= 0 else { return false }
        guard tokenStart + length <= tokenChars.count else { return false }
        guard candidateStart + length <= candidateChars.count else { return false }
        guard length > 0 else { return true }

        for offset in 0..<length where tokenChars[tokenStart + offset] != candidateChars[candidateStart + offset] {
            return false
        }
        return true
    }

    private static func stitchedWordPrefixScore(tokenChars: [Character], candidate: PreparedCandidateText) -> Int? {
        guard tokenChars.count >= 4 else { return nil }
        let candidateChars = candidate.characters
        let segments = candidate.wordSegments
        guard segments.count >= 2 else { return nil }

        struct StitchState: Hashable {
            let tokenIndex: Int
            let wordIndex: Int
            let usedWords: Int
        }

        var memo: [StitchState: Int?] = [:]

        func dfs(tokenIndex: Int, wordIndex: Int, usedWords: Int) -> Int? {
            if tokenIndex == tokenChars.count {
                return usedWords >= 2 ? 0 : nil
            }
            guard wordIndex < segments.count else { return nil }

            let state = StitchState(tokenIndex: tokenIndex, wordIndex: wordIndex, usedWords: usedWords)
            if let cached = memo[state] {
                return cached
            }

            var best: Int?
            let remainingChars = tokenChars.count - tokenIndex
            for segmentIndex in wordIndex..<segments.count {
                let segment = segments[segmentIndex]
                let segmentLength = segment.end - segment.start
                let maxChunk = min(segmentLength, remainingChars)
                guard maxChunk > 0 else { continue }

                let skippedWords = max(0, segmentIndex - wordIndex)
                let skipPenalty = skippedWords * 120
                for chunkLength in stride(from: maxChunk, through: 1, by: -1) {
                    guard tokenPrefixMatches(
                        tokenChars: tokenChars,
                        tokenStart: tokenIndex,
                        length: chunkLength,
                        candidateChars: candidateChars,
                        candidateStart: segment.start
                    ) else {
                        continue
                    }
                    guard let suffixScore = dfs(
                        tokenIndex: tokenIndex + chunkLength,
                        wordIndex: segmentIndex + 1,
                        usedWords: min(2, usedWords + 1)
                    ) else {
                        continue
                    }

                    let chunkCoverage = chunkLength * 220
                    let contiguityBonus = segmentIndex == wordIndex ? 80 : 0
                    let segmentRemainderPenalty = max(0, segmentLength - chunkLength) * 9
                    let distancePenalty = segment.start * 4
                    let chunkScore = chunkCoverage + contiguityBonus - segmentRemainderPenalty - distancePenalty - skipPenalty
                    let totalScore = suffixScore + chunkScore
                    best = max(best ?? totalScore, totalScore)
                }
            }

            memo[state] = best
            return best
        }

        guard let stitchedScore = dfs(tokenIndex: 0, wordIndex: 0, usedWords: 0) else { return nil }
        let lengthPenalty = max(0, candidateChars.count - tokenChars.count)
        return 3500 + stitchedScore - lengthPenalty
    }

    private static func stitchedWordPrefixMatchIndices(
        token: PreparedToken,
        candidate: PreparedCandidateText
    ) -> Set<Int>? {
        let tokenChars = token.characters
        let candidateChars = candidate.characters
        guard tokenChars.count >= 4 else { return nil }

        let segments = candidate.wordSegments
        guard segments.count >= 2 else { return nil }

        var tokenIndex = 0
        var nextWordIndex = 0
        var usedWords = 0
        var matchedIndices: Set<Int> = []

        while tokenIndex < tokenChars.count {
            let remainingChars = tokenChars.count - tokenIndex
            var foundMatch = false

            for segmentIndex in nextWordIndex..<segments.count {
                let segment = segments[segmentIndex]
                let segmentLength = segment.end - segment.start
                let maxChunk = min(segmentLength, remainingChars)
                guard maxChunk > 0 else { continue }

                for chunkLength in stride(from: maxChunk, through: 1, by: -1) {
                    guard tokenPrefixMatches(
                        tokenChars: tokenChars,
                        tokenStart: tokenIndex,
                        length: chunkLength,
                        candidateChars: candidateChars,
                        candidateStart: segment.start
                    ) else {
                        continue
                    }

                    matchedIndices.formUnion(segment.start..<(segment.start + chunkLength))
                    tokenIndex += chunkLength
                    nextWordIndex = segmentIndex + 1
                    usedWords += 1
                    foundMatch = true
                    break
                }

                if foundMatch { break }
            }

            if !foundMatch { return nil }
        }

        guard usedWords >= 2 else { return nil }
        return matchedIndices
    }

    private static func singleEditWordPrefixMatch(
        token: String,
        candidate: String
    ) -> SingleEditWordPrefixMatch? {
        singleEditWordPrefixMatch(
            tokenChars: Array(token),
            candidateChars: Array(candidate)
        )
    }

    private static func singleEditWordPrefixMatch(
        tokenChars: [Character],
        candidateChars: [Character]
    ) -> SingleEditWordPrefixMatch? {
        singleEditWordPrefixMatch(
            tokenChars: tokenChars,
            candidateChars: candidateChars,
            segments: wordSegments(candidateChars)
        )
    }

    private static func singleEditWordPrefixMatch(
        tokenChars: [Character],
        candidateChars: [Character],
        segments: [WordSegment]
    ) -> SingleEditWordPrefixMatch? {
        guard tokenChars.count >= 4 else { return nil }

        var bestMatch: SingleEditWordPrefixMatch?
        var bestScore: Int?

        for segment in segments {
            guard let match = singleEditWordPrefixMatch(
                tokenChars: tokenChars,
                candidateChars: candidateChars,
                segment: segment
            ) else {
                continue
            }

            let score = singleEditWordPrefixScore(match: match, candidateLength: candidateChars.count)
            if let bestScore, score <= bestScore {
                continue
            }
            bestScore = score
            bestMatch = match
        }

        return bestMatch
    }

    private static func singleEditWordPrefixMatch(
        tokenChars: [Character],
        candidateChars: [Character],
        segment: WordSegment
    ) -> SingleEditWordPrefixMatch? {
        guard tokenChars.count >= 4 else { return nil }

        let segmentLength = segment.end - segment.start
        guard segmentLength + 1 >= tokenChars.count else { return nil }

        let exactPrefixLength = min(tokenChars.count, segmentLength)
        var mismatchOffset = 0
        while mismatchOffset < exactPrefixLength,
            candidateChars[segment.start + mismatchOffset] == tokenChars[mismatchOffset]
        {
            mismatchOffset += 1
        }

        if mismatchOffset == tokenChars.count {
            let prefixLength = tokenChars.count + 1
            guard segmentLength >= prefixLength else { return nil }
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + tokenChars.count)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: prefixLength,
                editPosition: segment.start + tokenChars.count,
                editKind: .candidateExtraCharacter
            )
        }

        if mismatchOffset == segmentLength {
            let prefixLength = tokenChars.count - 1
            guard prefixLength > 0 else { return nil }
            guard tokenChars.count == segmentLength + 1 else { return nil }
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + prefixLength)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: prefixLength,
                editPosition: segment.start + prefixLength,
                editKind: .tokenExtraCharacter
            )
        }

        let mismatchCandidateIndex = segment.start + mismatchOffset

        if segmentLength >= tokenChars.count + 1,
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset,
                length: tokenChars.count - mismatchOffset,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex + 1
            )
        {
            var matchedIndices = Set(segment.start..<(segment.start + tokenChars.count + 1))
            matchedIndices.remove(mismatchCandidateIndex)
            return SingleEditWordPrefixMatch(
                matchedIndices: matchedIndices,
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count + 1,
                editPosition: mismatchCandidateIndex,
                editKind: .candidateExtraCharacter
            )
        }

        if tokenChars.count >= 2,
            segmentLength >= tokenChars.count - 1,
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset + 1,
                length: tokenChars.count - mismatchOffset - 1,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex
            )
        {
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + tokenChars.count - 1)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count - 1,
                editPosition: mismatchCandidateIndex,
                editKind: .tokenExtraCharacter
            )
        }

        if segmentLength >= tokenChars.count,
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset + 1,
                length: tokenChars.count - mismatchOffset - 1,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex + 1
            )
        {
            var matchedIndices = Set(segment.start..<(segment.start + tokenChars.count))
            matchedIndices.remove(mismatchCandidateIndex)
            return SingleEditWordPrefixMatch(
                matchedIndices: matchedIndices,
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count,
                editPosition: mismatchCandidateIndex,
                editKind: .substitutedCharacter
            )
        }

        if segmentLength >= tokenChars.count,
            mismatchOffset + 1 < tokenChars.count,
            mismatchCandidateIndex + 1 < segment.end,
            tokenChars[mismatchOffset] == candidateChars[mismatchCandidateIndex + 1],
            tokenChars[mismatchOffset + 1] == candidateChars[mismatchCandidateIndex],
            tokenPrefixMatches(
                tokenChars: tokenChars,
                tokenStart: mismatchOffset + 2,
                length: tokenChars.count - mismatchOffset - 2,
                candidateChars: candidateChars,
                candidateStart: mismatchCandidateIndex + 2
            )
        {
            return SingleEditWordPrefixMatch(
                matchedIndices: Set(segment.start..<(segment.start + tokenChars.count)),
                segmentStart: segment.start,
                segmentLength: segmentLength,
                prefixLength: tokenChars.count,
                editPosition: mismatchCandidateIndex,
                editKind: .transposedCharacters
            )
        }

        return nil
    }

    private static func wordSegments(_ candidateChars: [Character]) -> [WordSegment] {
        var segments: [WordSegment] = []
        var index = 0

        while index < candidateChars.count {
            while index < candidateChars.count, tokenBoundaryChars.contains(candidateChars[index]) {
                index += 1
            }
            guard index < candidateChars.count else { break }
            let start = index
            while index < candidateChars.count, !tokenBoundaryChars.contains(candidateChars[index]) {
                index += 1
            }
            segments.append(WordSegment(start: start, end: index))
        }

        return segments
    }

    private static func subsequenceScore(token: PreparedToken, candidate: PreparedCandidateText) -> Int? {
        let tokenChars = token.characters
        let candidateChars = candidate.characters
        guard tokenChars.count <= candidateChars.count else { return nil }

        var searchIndex = 0
        var previousMatch = -1
        var consecutiveRun = 0
        var score = 0

        for tokenChar in tokenChars {
            var foundIndex: Int?
            while searchIndex < candidateChars.count {
                if candidateChars[searchIndex] == tokenChar {
                    foundIndex = searchIndex
                    break
                }
                searchIndex += 1
            }
            guard let matchedIndex = foundIndex else { return nil }

            score += 90
            if matchedIndex == 0 || tokenBoundaryChars.contains(candidateChars[matchedIndex - 1]) {
                score += 140
            }
            if matchedIndex == previousMatch + 1 {
                consecutiveRun += 1
                score += min(200, consecutiveRun * 45)
            } else {
                consecutiveRun = 0
                score -= min(120, max(0, matchedIndex - previousMatch - 1) * 4)
            }

            previousMatch = matchedIndex
            searchIndex = matchedIndex + 1
        }

        score -= max(0, candidateChars.count - tokenChars.count)
        return max(1, score)
    }

    private static func subsequenceMatchIndices(token: PreparedToken, candidate: PreparedCandidateText) -> Set<Int>? {
        let tokenChars = token.characters
        let candidateChars = candidate.characters
        guard tokenChars.count <= candidateChars.count else { return nil }

        var indices: Set<Int> = []
        var searchIndex = 0

        for tokenChar in tokenChars {
            var foundIndex: Int?
            while searchIndex < candidateChars.count {
                if candidateChars[searchIndex] == tokenChar {
                    foundIndex = searchIndex
                    break
                }
                searchIndex += 1
            }
            guard let matchIndex = foundIndex else { return nil }
            indices.insert(matchIndex)
            searchIndex = matchIndex + 1
        }

        return indices
    }

    private static func initialismMatchIndices(token: PreparedToken, candidate: PreparedCandidateText) -> Set<Int>? {
        let tokenChars = token.characters
        let candidateChars = candidate.characters
        guard !tokenChars.isEmpty else { return nil }

        let segments = candidate.wordSegments
        guard tokenChars.count <= segments.count else { return nil }

        var matched: Set<Int> = []
        var searchWordIndex = 0

        for tokenChar in tokenChars {
            var found = false
            while searchWordIndex < segments.count {
                let segment = segments[searchWordIndex]
                searchWordIndex += 1
                if candidateChars[segment.start] == tokenChar {
                    matched.insert(segment.start)
                    found = true
                    break
                }
            }
            if !found { return nil }
        }

        return matched
    }
}
