import Foundation

struct CommandPaletteSwitcherSearchMetadata: Equatable, Sendable {
    let directories: [String]
    let branches: [String]
    let ports: [Int]
    let description: String?

    init(
        directories: [String] = [],
        branches: [String] = [],
        ports: [Int] = [],
        description: String? = nil
    ) {
        self.directories = directories
        self.branches = branches
        self.ports = ports
        self.description = description
    }
}
enum CommandPaletteSwitcherSearchIndexer {
    enum MetadataDetail {
        case workspace
        case surface
    }

    private static let metadataDelimiters = CharacterSet(charactersIn: "/\\.:_- ")

    static func keywords(
        baseKeywords: [String],
        metadata: CommandPaletteSwitcherSearchMetadata,
        detail: MetadataDetail = .surface
    ) -> [String] {
        let metadataKeywords = metadataKeywordsForSearch(metadata, detail: detail)
        return uniqueNormalizedPreservingOrder(baseKeywords + metadataKeywords)
    }

    private static func metadataKeywordsForSearch(
        _ metadata: CommandPaletteSwitcherSearchMetadata,
        detail: MetadataDetail
    ) -> [String] {
        let directoryTokens = metadata.directories.flatMap { directoryTokensForSearch($0, detail: detail) }
        let branchTokens = metadata.branches.flatMap { branchTokensForSearch($0, detail: detail) }
        let portTokens = metadata.ports.flatMap(portTokensForSearch)
        let descriptionTokens = descriptionTokensForSearch(metadata.description)

        var contextKeywords: [String] = []
        if !directoryTokens.isEmpty {
            contextKeywords.append(contentsOf: ["directory", "dir", "cwd", "path"])
        }
        if !branchTokens.isEmpty {
            contextKeywords.append(contentsOf: ["branch", "git"])
        }
        if !portTokens.isEmpty {
            contextKeywords.append(contentsOf: ["port", "ports"])
        }
        if !descriptionTokens.isEmpty {
            contextKeywords.append(contentsOf: ["description", "descriptions", "notes", "note"])
        }

        return contextKeywords + directoryTokens + branchTokens + portTokens + descriptionTokens
    }

    private static func directoryTokensForSearch(
        _ rawDirectory: String,
        detail: MetadataDetail
    ) -> [String] {
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let standardized = (trimmed as NSString).standardizingPath
        let canonical = standardized.isEmpty ? trimmed : standardized
        let abbreviated = (canonical as NSString).abbreviatingWithTildeInPath
        switch detail {
        case .workspace:
            return uniqueNormalizedPreservingOrder([trimmed, canonical, abbreviated])
        case .surface:
            let basename = URL(fileURLWithPath: canonical, isDirectory: true).lastPathComponent
            let components = canonical.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
            return uniqueNormalizedPreservingOrder(
                [trimmed, canonical, abbreviated, basename] + components
            )
        }
    }

    private static func branchTokensForSearch(
        _ rawBranch: String,
        detail: MetadataDetail
    ) -> [String] {
        let trimmed = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        switch detail {
        case .workspace:
            return [trimmed]
        case .surface:
            let components = trimmed.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
            return uniqueNormalizedPreservingOrder([trimmed] + components)
        }
    }

    private static func portTokensForSearch(_ port: Int) -> [String] {
        guard (1...65535).contains(port) else { return [] }
        let portText = String(port)
        return [portText, ":\(portText)"]
    }

    private static func descriptionTokensForSearch(_ rawDescription: String?) -> [String] {
        let trimmed = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return [] }
        let normalizedWhitespace = trimmed.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        let components = normalizedWhitespace.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
        return uniqueNormalizedPreservingOrder([trimmed, normalizedWhitespace] + components)
    }

    private static func uniqueNormalizedPreservingOrder(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        result.reserveCapacity(values.count)

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalizedKey = trimmed
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            guard seen.insert(normalizedKey).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

enum CommandPaletteFuzzyMatcher {
    private static let tokenBoundaryChars: Set<Character> = [" ", "-", "_", "/", ".", ":"]

    struct WordSegment: Hashable, Sendable {
        let start: Int
        let end: Int
    }

    struct ASCIIScalarMask: Equatable, Sendable {
        let low: UInt64
        let high: UInt64

        init(low: UInt64, high: UInt64) {
            self.low = low
            self.high = high
        }

        init(_ text: String) {
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

        func missingBitCount(from candidate: ASCIIScalarMask) -> Int {
            (low & ~candidate.low).nonzeroBitCount + (high & ~candidate.high).nonzeroBitCount
        }
    }

    struct PreparedToken: Equatable, Sendable {
        let normalizedText: String
        let characters: [Character]
        let asciiMask: ASCIIScalarMask
        let allowsSingleEdit: Bool
        let containsTokenBoundaryCharacter: Bool
        let scoreUpperBound: Int
        let scoreUpperBoundWithoutExactMatch: Int

        init(_ normalizedText: String) {
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

        func couldMatch(_ candidate: PreparedCandidateText) -> Bool {
            let missingCharacters = asciiMask.missingBitCount(from: candidate.asciiMask)
            return missingCharacters <= (allowsSingleEdit ? 1 : 0)
        }
    }

    struct PreparedCandidateText: Sendable {
        let normalizedText: String
        let characters: [Character]
        let wordSegments: [WordSegment]
        let asciiMask: ASCIIScalarMask

        init(normalizedText: String) {
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

    struct PreparedQuery {
        let normalizedText: String
        let tokens: [PreparedToken]

        var isEmpty: Bool {
            tokens.isEmpty
        }
    }

    static func preparedQuery(_ query: String) -> PreparedQuery {
        let normalizedQuery = normalizeForSearch(query)
        return PreparedQuery(
            normalizedText: normalizedQuery,
            tokens: normalizedQuery
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }
                .map(PreparedToken.init)
        )
    }

    static func normalizeForSearch(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    static func prepareCandidateText(_ candidate: String) -> PreparedCandidateText? {
        let normalizedCandidate = normalizeForSearch(candidate)
        guard !normalizedCandidate.isEmpty else { return nil }
        return PreparedCandidateText(normalizedText: normalizedCandidate)
    }

    static func prepareNormalizedCandidateText(_ normalizedCandidate: String) -> PreparedCandidateText? {
        guard !normalizedCandidate.isEmpty else { return nil }
        return PreparedCandidateText(normalizedText: normalizedCandidate)
    }

    static func score(query: String, candidate: String) -> Int? {
        score(query: query, candidates: [candidate])
    }

    static func score(query: String, candidates: [String]) -> Int? {
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

    static func score(preparedQuery: PreparedQuery, normalizedCandidates: [String]) -> Int? {
        score(
            preparedQuery: preparedQuery,
            preparedCandidates: normalizedCandidates.compactMap(prepareNormalizedCandidateText),
            exactCandidateTexts: Set(normalizedCandidates)
        )
    }

    static func score(preparedQuery: PreparedQuery, preparedCandidates: [PreparedCandidateText]) -> Int? {
        score(
            preparedQuery: preparedQuery,
            preparedCandidates: preparedCandidates,
            exactCandidateTexts: nil
        )
    }

    static func score(preparedQuery: PreparedQuery, preparedCandidate: PreparedCandidateText) -> Int? {
        guard !preparedQuery.isEmpty else { return 0 }

        var totalScore = 0
        for token in preparedQuery.tokens {
            guard token.couldMatch(preparedCandidate) else { return nil }
            guard let tokenScore = scoreToken(token, in: preparedCandidate) else { return nil }
            totalScore += tokenScore
        }
        return totalScore
    }

    static func score(
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

    static func wholeCandidatePrefixScoreByToken(
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

    static func matchCharacterIndices(query: String, candidate: String) -> Set<Int> {
        matchCharacterIndices(preparedQuery: preparedQuery(query), candidate: candidate)
    }

    static func matchCharacterIndices(preparedQuery: PreparedQuery, candidate: String) -> Set<Int> {
        guard !preparedQuery.isEmpty else { return [] }

        guard let preparedCandidate = prepareCandidateText(candidate) else { return [] }
        return matchCharacterIndices(preparedQuery: preparedQuery, preparedCandidate: preparedCandidate)
    }

    static func matchCharacterIndices(
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

    static func tokenCanMatchWithoutSingleEdit(
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

    static func usesSingleEditWordPrefix(
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

struct CommandPaletteSearchCorpusEntry<Payload>: Sendable where Payload: Sendable {
    let payload: Payload
    let rank: Int
    let title: String
    let preparedTitle: CommandPaletteFuzzyMatcher.PreparedCandidateText?
    let preparedSearchableTexts: [CommandPaletteFuzzyMatcher.PreparedCandidateText]
    let searchableTextSet: Set<String>
    let searchablePrefixScoreByToken: [String: Int]
    let nucleoSearchText: String

    init(payload: Payload, rank: Int, title: String, searchableTexts: [String]) {
        self.payload = payload
        self.rank = rank
        self.title = title
        let normalizedTitle = CommandPaletteFuzzyMatcher.normalizeForSearch(title)
        self.preparedTitle = CommandPaletteFuzzyMatcher.prepareNormalizedCandidateText(normalizedTitle)

        var nucleoSearchTexts: [String] = []
        var normalizedTexts: [String] = []
        var seen: Set<String> = []
        normalizedTexts.reserveCapacity(searchableTexts.count)
        nucleoSearchTexts.reserveCapacity(searchableTexts.count)
        for text in searchableTexts {
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                nucleoSearchTexts.append(trimmedText)
            }
            let normalizedText = CommandPaletteFuzzyMatcher.normalizeForSearch(text)
            guard !normalizedText.isEmpty else { continue }
            guard seen.insert(normalizedText).inserted else { continue }
            normalizedTexts.append(normalizedText)
        }

        let preparedSearchableTexts = normalizedTexts.compactMap(
            CommandPaletteFuzzyMatcher.prepareNormalizedCandidateText
        )
        self.preparedSearchableTexts = preparedSearchableTexts
        self.searchableTextSet = Set(normalizedTexts)
        self.searchablePrefixScoreByToken = CommandPaletteFuzzyMatcher.wholeCandidatePrefixScoreByToken(
            preparedCandidates: preparedSearchableTexts
        )
        self.nucleoSearchText = nucleoSearchTexts.joined(separator: "\n")
    }
}

struct CommandPaletteSearchCorpusResult<Payload>: Sendable where Payload: Sendable {
    let payload: Payload
    let rank: Int
    let title: String
    let score: Int
    let titleMatchIndices: Set<Int>
}

enum CommandPaletteSearchEngine {
    private static let titleMatchBonus = 2000

    private struct ScoredEntry<Payload>: Sendable where Payload: Sendable {
        let entry: CommandPaletteSearchCorpusEntry<Payload>
        let index: Int
        let score: Int
    }

    private static func scoredEntryIsBetter<Payload: Sendable>(
        _ lhs: ScoredEntry<Payload>,
        than rhs: ScoredEntry<Payload>
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.entry.rank != rhs.entry.rank { return lhs.entry.rank < rhs.entry.rank }
        let titleComparison = lhs.entry.title.localizedCaseInsensitiveCompare(rhs.entry.title)
        if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
        return lhs.index < rhs.index
    }

    private static func scoredEntryIsWorse<Payload: Sendable>(
        _ lhs: ScoredEntry<Payload>,
        than rhs: ScoredEntry<Payload>
    ) -> Bool {
        scoredEntryIsBetter(rhs, than: lhs)
    }

    private static func siftUpWorstScoredEntryHeap<Payload: Sendable>(
        _ heap: inout [ScoredEntry<Payload>],
        from startIndex: Int
    ) {
        var child = startIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard scoredEntryIsWorse(heap[child], than: heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private static func siftDownWorstScoredEntryHeap<Payload: Sendable>(
        _ heap: inout [ScoredEntry<Payload>],
        from startIndex: Int
    ) {
        var parent = startIndex
        while true {
            let leftChild = (parent * 2) + 1
            guard leftChild < heap.count else { return }

            let rightChild = leftChild + 1
            var worstChild = leftChild
            if rightChild < heap.count,
               scoredEntryIsWorse(heap[rightChild], than: heap[leftChild]) {
                worstChild = rightChild
            }

            guard scoredEntryIsWorse(heap[worstChild], than: heap[parent]) else { return }
            heap.swapAt(parent, worstChild)
            parent = worstChild
        }
    }

    private static func appendScoredEntry<Payload: Sendable>(
        _ scoredEntry: ScoredEntry<Payload>,
        to scoredEntries: inout [ScoredEntry<Payload>],
        limit: Int?
    ) {
        guard let limit else {
            scoredEntries.append(scoredEntry)
            return
        }

        if scoredEntries.count < limit {
            scoredEntries.append(scoredEntry)
            siftUpWorstScoredEntryHeap(&scoredEntries, from: scoredEntries.count - 1)
            return
        }

        guard let worstEntry = scoredEntries.first,
              scoredEntryIsBetter(scoredEntry, than: worstEntry) else {
            return
        }
        scoredEntries[0] = scoredEntry
        siftDownWorstScoredEntryHeap(&scoredEntries, from: 0)
    }

    static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        resultLimit: Int? = nil,
        historyBoost: (Payload, Bool) -> Int
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        search(
            entries: entries,
            query: query,
            resultLimit: resultLimit,
            historyBoost: historyBoost,
            shouldCancel: nil
        )
    }

    static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        resultLimit: Int? = nil,
        historyBoost: (Payload, Bool) -> Int,
        shouldCancel: @escaping () -> Bool
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        search(
            entries: entries,
            query: query,
            resultLimit: resultLimit,
            historyBoost: historyBoost,
            shouldCancel: Optional(shouldCancel)
        )
    }

    private static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        resultLimit: Int?,
        historyBoost: (Payload, Bool) -> Int,
        shouldCancel: (() -> Bool)?
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        if let resultLimit, resultLimit <= 0 {
            return []
        }
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        let queryIsEmpty = preparedQuery.isEmpty
        let limitedResultCount = resultLimit.map { min($0, entries.count) }
        var scoredEntries: [ScoredEntry<Payload>] = []
        scoredEntries.reserveCapacity(limitedResultCount ?? entries.count)

        func shouldCancelSearch(at index: Int) -> Bool {
            guard let shouldCancel else { return false }
            return index % 16 == 0 && shouldCancel()
        }

        if queryIsEmpty {
            for (index, entry) in entries.enumerated() {
                if shouldCancelSearch(at: index) { return [] }
                appendScoredEntry(
                    ScoredEntry(
                        entry: entry,
                        index: index,
                        score: historyBoost(entry.payload, true)
                    ),
                    to: &scoredEntries,
                    limit: limitedResultCount
                )
            }
        } else {
            for (index, entry) in entries.enumerated() {
                if shouldCancelSearch(at: index) { return [] }
                guard let fuzzyScore = weightedScore(
                    preparedQuery: preparedQuery,
                    entry: entry
                ) else {
                    continue
                }
                appendScoredEntry(
                    ScoredEntry(
                        entry: entry,
                        index: index,
                        score: fuzzyScore + historyBoost(entry.payload, false)
                    ),
                    to: &scoredEntries,
                    limit: limitedResultCount
                )
            }
        }

        if shouldCancel?() == true { return [] }

        scoredEntries.sort { scoredEntryIsBetter($0, than: $1) }

        let outputCount = resultLimit.map { min($0, scoredEntries.count) } ?? scoredEntries.count
        var results: [CommandPaletteSearchCorpusResult<Payload>] = []
        results.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            if shouldCancelSearch(at: index) { return [] }
            let scoredEntry = scoredEntries[index]
            let entry = scoredEntry.entry
            let titleMatchIndices: Set<Int>
            if queryIsEmpty {
                titleMatchIndices = []
            } else {
                titleMatchIndices = entry.preparedTitle.map {
                    CommandPaletteFuzzyMatcher.matchCharacterIndices(
                        preparedQuery: preparedQuery,
                        preparedCandidate: $0
                    )
                } ?? []
            }
            results.append(
                CommandPaletteSearchCorpusResult(
                    payload: entry.payload,
                    rank: entry.rank,
                    title: entry.title,
                    score: scoredEntry.score,
                    titleMatchIndices: titleMatchIndices
                )
            )
        }
        return results
    }

    private static func weightedScore<Payload: Sendable>(
        preparedQuery: CommandPaletteFuzzyMatcher.PreparedQuery,
        entry: CommandPaletteSearchCorpusEntry<Payload>
    ) -> Int? {
        guard let fuzzyScore = CommandPaletteFuzzyMatcher.score(
            preparedQuery: preparedQuery,
            preparedCandidates: entry.preparedSearchableTexts,
            exactCandidateTexts: entry.searchableTextSet,
            wholeCandidatePrefixScoreByToken: entry.searchablePrefixScoreByToken
        ) else {
            return nil
        }
        if let preparedTitle = entry.preparedTitle,
           preparedQuery.tokens.allSatisfy({ $0.couldMatch(preparedTitle) }),
           let titleScore = CommandPaletteFuzzyMatcher.score(
                preparedQuery: preparedQuery,
                preparedCandidate: preparedTitle
            ) {
            return max(fuzzyScore, titleScore + titleMatchBonus)
        }
        return fuzzyScore
    }
}
