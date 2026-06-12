import Foundation

enum CommandPaletteFuzzyMatcher {
    static let tokenBoundaryChars: Set<Character> = [" ", "-", "_", "/", ".", ":"]

    struct WordSegment: Hashable, Sendable {
        let start: Int
        let end: Int
    }

    struct ASCIIScalarMask: Equatable, Sendable {
        let low: UInt64
        let high: UInt64

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

    struct PreparedQuery {
        let tokens: [PreparedToken]

        var isEmpty: Bool {
            tokens.isEmpty
        }
    }

    static func preparedQuery(_ query: String) -> PreparedQuery {
        let normalizedQuery = normalizeForSearch(query)
        return PreparedQuery(
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

    static func wordSegments(_ candidateChars: [Character]) -> [WordSegment] {
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

}

