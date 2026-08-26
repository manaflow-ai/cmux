import Foundation

/// Matches `*` and `?` URL rules in linear time without regex backtracking.
struct BrowserExternalURLWildcardPattern: Sendable {
    private let maximumPatternLength = 256
    private let maximumMatchOperations = 1_000_000
    private let tokens: [BrowserExternalURLWildcardToken]

    /// Parses one glob, preserving backslash-escaped wildcard characters.
    init?(pattern: String) {
        guard pattern.utf8.prefix(maximumPatternLength + 1).count <= maximumPatternLength else {
            return nil
        }
        var parsed: [BrowserExternalURLWildcardToken] = []
        parsed.reserveCapacity(pattern.count)
        var isEscaping = false

        // Pattern matching preserves the legacy substring behavior of the
        // regex implementation, so every glob has an implicit `*` at both
        // ends unless one is already present.
        parsed.append(BrowserExternalURLWildcardToken(kind: 0, literal: nil))

        for character in pattern {
            if isEscaping {
                parsed.append(
                    BrowserExternalURLWildcardToken(
                        kind: 2,
                        literal: String(character).lowercased()
                    )
                )
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            switch character {
            case "*":
                // Consecutive stars are equivalent to one star and should
                // not create repeated ambiguous search states.
                if parsed.last?.kind != 0 {
                    parsed.append(BrowserExternalURLWildcardToken(kind: 0, literal: nil))
                }
            case "?":
                parsed.append(BrowserExternalURLWildcardToken(kind: 1, literal: nil))
            default:
                parsed.append(
                    BrowserExternalURLWildcardToken(
                        kind: 2,
                        literal: String(character).lowercased()
                    )
                )
            }
        }
        if isEscaping {
            parsed.append(BrowserExternalURLWildcardToken(kind: 2, literal: "\\"))
        }
        if parsed.last?.kind != 0 {
            parsed.append(BrowserExternalURLWildcardToken(kind: 0, literal: nil))
        }
        tokens = parsed
    }

    /// Returns whether the glob matches `target` using a bounded greedy scan.
    func matches(_ target: String) -> Bool {
        let characters = target.lowercased().map(String.init)
        var tokenIndex = 0
        var characterIndex = 0
        var lastStarIndex: Int?
        var starMatchIndex = 0
        var operations = 0

        while characterIndex < characters.count {
            operations += 1
            guard operations <= maximumMatchOperations else { return false }
            if tokenIndex < tokens.count,
               tokens[tokenIndex].kind != 0,
               tokenMatches(tokens[tokenIndex], character: characters[characterIndex]) {
                tokenIndex += 1
                characterIndex += 1
                continue
            }

            if tokenIndex < tokens.count, tokens[tokenIndex].kind == 0 {
                lastStarIndex = tokenIndex
                tokenIndex += 1
                starMatchIndex = characterIndex
                continue
            }

            if let lastStarIndex,
               starMatchIndex < characters.count {
                tokenIndex = lastStarIndex + 1
                starMatchIndex += 1
                characterIndex = starMatchIndex
                continue
            }
            return false
        }

        while tokenIndex < tokens.count, tokens[tokenIndex].kind == 0 {
            tokenIndex += 1
        }
        return tokenIndex == tokens.count
    }

    private func tokenMatches(
        _ token: BrowserExternalURLWildcardToken,
        character: String
    ) -> Bool {
        guard token.kind == 1 else {
            guard let literal = token.literal else { return false }
            return character == literal
        }
        return true
    }
}
