import Foundation


// MARK: - Scoring
extension CommandPaletteFuzzyMatcher {
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

    static func tokenPrefixMatches(
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

}
