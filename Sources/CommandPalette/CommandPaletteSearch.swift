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
                return 10
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
        let tokens: [String]

        var isEmpty: Bool {
            tokens.isEmpty
        }
    }

    static func preparedQuery(_ query: String) -> PreparedQuery {
        let normalizedQuery = normalizeForSearch(query)
        return PreparedQuery(
            normalizedText: normalizedQuery,
            tokens: normalizedQuery.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        )
    }

    static func normalizeForSearch(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    static func score(query: String, candidate: String) -> Int? {
        score(query: query, candidates: [candidate])
    }

    static func score(query: String, candidates: [String]) -> Int? {
        score(
            preparedQuery: preparedQuery(query),
            normalizedCandidates: candidates
                .map(normalizeForSearch)
                .filter { !$0.isEmpty }
        )
    }

    static func score(preparedQuery: PreparedQuery, normalizedCandidates: [String]) -> Int? {
        guard !preparedQuery.isEmpty else { return 0 }
        guard !normalizedCandidates.isEmpty else { return nil }

        var totalScore = 0
        for token in preparedQuery.tokens {
            var bestTokenScore: Int?
            for candidate in normalizedCandidates {
                guard let candidateScore = scoreToken(token, in: candidate) else { continue }
                bestTokenScore = max(bestTokenScore ?? candidateScore, candidateScore)
            }
            guard let bestTokenScore else { return nil }
            totalScore += bestTokenScore
        }
        return totalScore
    }

    static func matchCharacterIndices(query: String, candidate: String) -> Set<Int> {
        matchCharacterIndices(preparedQuery: preparedQuery(query), candidate: candidate)
    }

    static func matchCharacterIndices(preparedQuery: PreparedQuery, candidate: String) -> Set<Int> {
        guard !preparedQuery.isEmpty else { return [] }

        let loweredCandidate = normalizeForSearch(candidate)
        guard !loweredCandidate.isEmpty else { return [] }

        let candidateChars = Array(loweredCandidate)
        var matched: Set<Int> = []

        for token in preparedQuery.tokens {
            if token == loweredCandidate {
                matched.formUnion(0..<candidateChars.count)
                continue
            }

            if loweredCandidate.hasPrefix(token) {
                matched.formUnion(0..<min(token.count, candidateChars.count))
                continue
            }

            if let range = loweredCandidate.range(of: token) {
                let start = loweredCandidate.distance(from: loweredCandidate.startIndex, to: range.lowerBound)
                let end = min(candidateChars.count, start + token.count)
                matched.formUnion(start..<end)
                continue
            }

            if let singleEditPrefix = singleEditWordPrefixMatch(token: token, candidate: loweredCandidate) {
                matched.formUnion(singleEditPrefix.matchedIndices)
                continue
            }

            if let initialism = initialismMatchIndices(token: token, candidate: loweredCandidate) {
                matched.formUnion(initialism)
                continue
            }

            if let stitched = stitchedWordPrefixMatchIndices(token: token, candidate: loweredCandidate) {
                matched.formUnion(stitched)
                continue
            }

            guard token.count <= 3 else { continue }
            if let subsequence = subsequenceMatchIndices(token: token, candidate: loweredCandidate) {
                matched.formUnion(subsequence)
            }
        }

        return matched
    }

    private static func scoreToken(_ token: String, in candidate: String) -> Int? {
        guard !token.isEmpty else { return 0 }

        let candidateChars = Array(candidate)
        let tokenChars = Array(token)
        guard tokenChars.count <= candidateChars.count else { return nil }

        if token == candidate {
            return 8000
        }
        if candidate.hasPrefix(token) {
            return 6800 - max(0, candidate.count - token.count)
        }

        var bestScore: Int?
        if let wordExactScore = bestWordScore(tokenChars: tokenChars, candidateChars: candidateChars, requireExactWord: true) {
            bestScore = max(bestScore ?? wordExactScore, wordExactScore)
        }
        if let wordPrefixScore = bestWordScore(tokenChars: tokenChars, candidateChars: candidateChars, requireExactWord: false) {
            bestScore = max(bestScore ?? wordPrefixScore, wordPrefixScore)
        }
        if let singleEditPrefixScore = singleEditWordPrefixScore(
            tokenChars: tokenChars,
            candidateChars: candidateChars
        ) {
            bestScore = max(bestScore ?? singleEditPrefixScore, singleEditPrefixScore)
        }

        if let range = candidate.range(of: token) {
            let distance = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            let lengthPenalty = max(0, candidate.count - token.count)
            let boundaryBoost: Int = {
                guard distance > 0 else { return 220 }
                let prior = candidateChars[distance - 1]
                return tokenBoundaryChars.contains(prior) ? 180 : 0
            }()
            let containsScore = 4200 + boundaryBoost - (distance * 9) - lengthPenalty
            bestScore = max(bestScore ?? containsScore, containsScore)
        }

        if let initialismScore = initialismScore(tokenChars: tokenChars, candidateChars: candidateChars) {
            bestScore = max(bestScore ?? initialismScore, initialismScore)
        }

        if let stitchedScore = stitchedWordPrefixScore(tokenChars: tokenChars, candidateChars: candidateChars) {
            bestScore = max(bestScore ?? stitchedScore, stitchedScore)
        }

        if tokenChars.count <= 3, let subsequence = subsequenceScore(token: token, candidate: candidate) {
            bestScore = max(bestScore ?? subsequence, subsequence)
        }

        guard let bestScore else { return nil }
        return max(1, bestScore)
    }

    private static func bestWordScore(
        tokenChars: [Character],
        candidateChars: [Character],
        requireExactWord: Bool
    ) -> Int? {
        guard !tokenChars.isEmpty else { return nil }

        var best: Int?
        for segment in wordSegments(candidateChars) {
            let wordLength = segment.end - segment.start
            guard tokenChars.count <= wordLength else { continue }

            var matchesPrefix = true
            for offset in 0..<tokenChars.count where candidateChars[segment.start + offset] != tokenChars[offset] {
                matchesPrefix = false
                break
            }
            guard matchesPrefix else { continue }
            if requireExactWord && tokenChars.count != wordLength { continue }

            let lengthPenalty = max(0, wordLength - tokenChars.count) * 6
            let distancePenalty = segment.start * 8
            let trailingPenalty = max(0, candidateChars.count - wordLength)
            let scoreBase = requireExactWord ? 6200 : 5600
            let score = scoreBase - distancePenalty - lengthPenalty - trailingPenalty
            best = max(best ?? score, score)
        }

        return best
    }

    private static func singleEditWordPrefixScore(
        tokenChars: [Character],
        candidateChars: [Character]
    ) -> Int? {
        guard let match = singleEditWordPrefixMatch(
            tokenChars: tokenChars,
            candidateChars: candidateChars
        ) else {
            return nil
        }
        return singleEditWordPrefixScore(match: match, candidateLength: candidateChars.count)
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

    private static func initialismScore(tokenChars: [Character], candidateChars: [Character]) -> Int? {
        guard !tokenChars.isEmpty else { return nil }
        let segments = wordSegments(candidateChars)
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

    private static func stitchedWordPrefixScore(tokenChars: [Character], candidateChars: [Character]) -> Int? {
        guard tokenChars.count >= 4 else { return nil }
        let segments = wordSegments(candidateChars)
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

    private static func stitchedWordPrefixMatchIndices(token: String, candidate: String) -> Set<Int>? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
        guard tokenChars.count >= 4 else { return nil }

        let segments = wordSegments(candidateChars)
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
        guard tokenChars.count >= 4 else { return nil }

        var bestMatch: SingleEditWordPrefixMatch?
        var bestScore: Int?

        for segment in wordSegments(candidateChars) {
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
        segment: (start: Int, end: Int)
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

    private static func wordSegments(_ candidateChars: [Character]) -> [(start: Int, end: Int)] {
        var segments: [(start: Int, end: Int)] = []
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
            segments.append((start: start, end: index))
        }

        return segments
    }

    private static func subsequenceScore(token: String, candidate: String) -> Int? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
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

    private static func subsequenceMatchIndices(token: String, candidate: String) -> Set<Int>? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
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

    private static func initialismMatchIndices(token: String, candidate: String) -> Set<Int>? {
        let tokenChars = Array(token)
        let candidateChars = Array(candidate)
        guard !tokenChars.isEmpty else { return nil }

        let segments = wordSegments(candidateChars)
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
    let normalizedTitle: String
    let normalizedSearchableTexts: [String]

    init(payload: Payload, rank: Int, title: String, searchableTexts: [String]) {
        self.payload = payload
        self.rank = rank
        self.title = title
        self.normalizedTitle = CommandPaletteFuzzyMatcher.normalizeForSearch(title)
        self.normalizedSearchableTexts = searchableTexts
            .map(CommandPaletteFuzzyMatcher.normalizeForSearch)
            .filter { !$0.isEmpty }
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

    static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        historyBoost: (Payload, Bool) -> Int
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        search(
            entries: entries,
            query: query,
            historyBoost: historyBoost,
            shouldCancel: nil
        )
    }

    static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        historyBoost: (Payload, Bool) -> Int,
        shouldCancel: @escaping () -> Bool
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        search(
            entries: entries,
            query: query,
            historyBoost: historyBoost,
            shouldCancel: Optional(shouldCancel)
        )
    }

    private static func search<Payload: Sendable>(
        entries: [CommandPaletteSearchCorpusEntry<Payload>],
        query: String,
        historyBoost: (Payload, Bool) -> Int,
        shouldCancel: (() -> Bool)?
    ) -> [CommandPaletteSearchCorpusResult<Payload>] {
        let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
        let queryIsEmpty = preparedQuery.isEmpty
        var results: [CommandPaletteSearchCorpusResult<Payload>] = []
        results.reserveCapacity(entries.count)

        func shouldCancelSearch(at index: Int) -> Bool {
            guard let shouldCancel else { return false }
            return index % 16 == 0 && shouldCancel()
        }

        if queryIsEmpty {
            for (index, entry) in entries.enumerated() {
                if shouldCancelSearch(at: index) { return [] }
                results.append(
                    CommandPaletteSearchCorpusResult(
                    payload: entry.payload,
                    rank: entry.rank,
                    title: entry.title,
                    score: historyBoost(entry.payload, true),
                    titleMatchIndices: []
                )
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
                results.append(
                    CommandPaletteSearchCorpusResult(
                        payload: entry.payload,
                        rank: entry.rank,
                        title: entry.title,
                        score: fuzzyScore + historyBoost(entry.payload, false),
                        titleMatchIndices: CommandPaletteFuzzyMatcher.matchCharacterIndices(
                            preparedQuery: preparedQuery,
                            candidate: entry.title
                        )
                    )
                )
            }
        }

        if shouldCancel?() == true { return [] }

        return results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func weightedScore<Payload: Sendable>(
        preparedQuery: CommandPaletteFuzzyMatcher.PreparedQuery,
        entry: CommandPaletteSearchCorpusEntry<Payload>
    ) -> Int? {
        guard let fuzzyScore = CommandPaletteFuzzyMatcher.score(
                    preparedQuery: preparedQuery,
                    normalizedCandidates: entry.normalizedSearchableTexts
                ) else {
            return nil
        }
        guard !entry.normalizedTitle.isEmpty,
              let titleScore = CommandPaletteFuzzyMatcher.score(
                preparedQuery: preparedQuery,
                normalizedCandidates: [entry.normalizedTitle]
              ) else {
            return fuzzyScore
        }
        return max(fuzzyScore, titleScore + titleMatchBonus)
    }
}
