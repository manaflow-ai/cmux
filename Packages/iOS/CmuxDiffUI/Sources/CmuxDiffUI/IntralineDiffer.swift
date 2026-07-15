import Foundation

struct IntralineDiffer: Sendable {
    func changedRanges(old: String, new: String) -> (old: TextRange?, new: TextRange?) {
        guard old != new else { return (nil, nil) }
        let oldTokens = tokens(in: old)
        let newTokens = tokens(in: new)
        var prefixCount = 0
        while prefixCount < min(oldTokens.count, newTokens.count),
              oldTokens[prefixCount].text == newTokens[prefixCount].text {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < min(oldTokens.count - prefixCount, newTokens.count - prefixCount),
              oldTokens[oldTokens.count - suffixCount - 1].text
                == newTokens[newTokens.count - suffixCount - 1].text {
            suffixCount += 1
        }

        return (
            changedRange(tokens: oldTokens, prefixCount: prefixCount, suffixCount: suffixCount, text: old),
            changedRange(tokens: newTokens, prefixCount: prefixCount, suffixCount: suffixCount, text: new)
        )
    }

    func spans(text: String, emphasizedRange: TextRange?) -> [IntralineSpan] {
        guard let emphasizedRange, !emphasizedRange.isEmpty else {
            return [IntralineSpan(text: text, isEmphasized: false)]
        }
        let characters = Array(text)
        var result: [IntralineSpan] = []
        if emphasizedRange.lowerBound > 0 {
            result.append(IntralineSpan(
                text: String(characters[0..<emphasizedRange.lowerBound]),
                isEmphasized: false
            ))
        }
        result.append(IntralineSpan(
            text: String(characters[emphasizedRange.lowerBound..<emphasizedRange.upperBound]),
            isEmphasized: true
        ))
        if emphasizedRange.upperBound < characters.count {
            result.append(IntralineSpan(
                text: String(characters[emphasizedRange.upperBound..<characters.count]),
                isEmphasized: false
            ))
        }
        return result
    }

    private func changedRange(
        tokens: [IntralineToken],
        prefixCount: Int,
        suffixCount: Int,
        text: String
    ) -> TextRange? {
        let characterCount = text.count
        let lower = prefixCount < tokens.count ? tokens[prefixCount].range.lowerBound : characterCount
        let suffixIndex = tokens.count - suffixCount
        let upper = suffixIndex > 0 ? tokens[suffixIndex - 1].range.upperBound : 0
        let range = TextRange(lowerBound: lower, upperBound: max(lower, upper))
        return range.isEmpty ? nil : range
    }

    private func tokens(in text: String) -> [IntralineToken] {
        var result: [IntralineToken] = []
        var current = ""
        var currentCategory: IntralineToken.Category?
        var tokenStart = 0
        var offset = 0

        for character in text {
            let category = category(for: character)
            if let currentCategory, currentCategory != category {
                result.append(IntralineToken(
                    text: current,
                    category: currentCategory,
                    range: TextRange(lowerBound: tokenStart, upperBound: offset)
                ))
                current = ""
                tokenStart = offset
            }
            currentCategory = category
            current.append(character)
            offset += 1
        }

        if let currentCategory {
            result.append(IntralineToken(
                text: current,
                category: currentCategory,
                range: TextRange(lowerBound: tokenStart, upperBound: offset)
            ))
        }
        return result
    }

    private func category(for character: Character) -> IntralineToken.Category {
        if character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return .whitespace
        }
        if character.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }) {
            return .word
        }
        return .punctuation
    }
}
