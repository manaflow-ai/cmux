internal import Foundation

/// Computes bounded character ranges for stronger word-level diff tinting.
struct IntralineWordDiff: Sendable {
    /// Maximum characters accepted on either side.
    let maximumLineLength: Int

    /// Creates a bounded intraline differ.
    /// - Parameter maximumLineLength: Work is skipped above this character count.
    init(maximumLineLength: Int = 1_000) {
        self.maximumLineLength = maximumLineLength
    }

    /// Finds changed character ranges on both sides of one paired line.
    /// - Parameters:
    ///   - old: Deleted-line text.
    ///   - new: Added-line text.
    /// - Returns: Changed ranges for the old and new text, or empty ranges when capped.
    func ranges(old: String, new: String) -> (old: [DiffCharacterRange], new: [DiffCharacterRange]) {
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        guard oldCharacters.count <= maximumLineLength, newCharacters.count <= maximumLineLength else {
            return ([], [])
        }
        guard old != new else { return ([], []) }

        let prefix = commonPrefix(oldCharacters, newCharacters)
        let suffix = commonSuffix(oldCharacters, newCharacters, prefix: prefix)
        let oldLimit = oldCharacters.count - suffix
        let newLimit = newCharacters.count - suffix
        let oldTokens = tokens(in: oldCharacters, range: prefix..<oldLimit)
        let newTokens = tokens(in: newCharacters, range: prefix..<newLimit)
        let matches = longestCommonSubsequence(oldTokens, newTokens)

        var oldUnchanged = prefix > 0 ? [0..<prefix] : []
        var newUnchanged = prefix > 0 ? [0..<prefix] : []
        for match in matches {
            oldUnchanged.append(oldTokens[match.old].range)
            newUnchanged.append(newTokens[match.new].range)
        }
        if suffix > 0 {
            oldUnchanged.append(oldLimit..<oldCharacters.count)
            newUnchanged.append(newLimit..<newCharacters.count)
        }
        return (
            changedRanges(length: oldCharacters.count, unchanged: oldUnchanged),
            changedRanges(length: newCharacters.count, unchanged: newUnchanged)
        )
    }

    private struct Token: Equatable {
        let value: String
        let range: Range<Int>
    }

    private struct Match {
        let old: Int
        let new: Int
    }

    private func commonPrefix(_ old: [Character], _ new: [Character]) -> Int {
        var count = 0
        while count < old.count, count < new.count, old[count] == new[count] { count += 1 }
        return count
    }

    private func commonSuffix(_ old: [Character], _ new: [Character], prefix: Int) -> Int {
        var count = 0
        while old.count - count > prefix,
              new.count - count > prefix,
              old[old.count - count - 1] == new[new.count - count - 1] {
            count += 1
        }
        return count
    }

    private func tokens(in characters: [Character], range: Range<Int>) -> [Token] {
        guard !range.isEmpty else { return [] }
        var result: [Token] = []
        var start = range.lowerBound
        var category = tokenCategory(characters[start])
        for offset in (start + 1)..<range.upperBound {
            let next = tokenCategory(characters[offset])
            if next != category || next == .punctuation {
                result.append(Token(value: String(characters[start..<offset]), range: start..<offset))
                start = offset
                category = next
            }
        }
        result.append(Token(value: String(characters[start..<range.upperBound]), range: start..<range.upperBound))
        return result
    }

    private enum TokenCategory {
        case word
        case whitespace
        case punctuation
    }

    private func tokenCategory(_ character: Character) -> TokenCategory {
        if character.unicodeScalars.allSatisfy(\.properties.isWhitespace) { return .whitespace }
        if character.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" }) {
            return .word
        }
        return .punctuation
    }

    private func longestCommonSubsequence(_ old: [Token], _ new: [Token]) -> [Match] {
        guard !old.isEmpty, !new.isEmpty else { return [] }
        var lengths = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for oldIndex in old.indices.reversed() {
            for newIndex in new.indices.reversed() {
                lengths[oldIndex][newIndex] = old[oldIndex].value == new[newIndex].value
                    ? lengths[oldIndex + 1][newIndex + 1] + 1
                    : max(lengths[oldIndex + 1][newIndex], lengths[oldIndex][newIndex + 1])
            }
        }
        var result: [Match] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count, newIndex < new.count {
            if old[oldIndex].value == new[newIndex].value {
                result.append(Match(old: oldIndex, new: newIndex))
                oldIndex += 1
                newIndex += 1
            } else if lengths[oldIndex + 1][newIndex] >= lengths[oldIndex][newIndex + 1] {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        return result
    }

    private func changedRanges(length: Int, unchanged: [Range<Int>]) -> [DiffCharacterRange] {
        let ordered = unchanged.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        var result: [DiffCharacterRange] = []
        var cursor = 0
        for range in ordered {
            if range.lowerBound > cursor {
                result.append(DiffCharacterRange(lowerBound: cursor, upperBound: range.lowerBound))
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < length {
            result.append(DiffCharacterRange(lowerBound: cursor, upperBound: length))
        }
        return result
    }
}
