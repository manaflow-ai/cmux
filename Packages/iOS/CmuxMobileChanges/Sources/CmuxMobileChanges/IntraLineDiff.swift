/// Pure grapheme-safe intra-line emphasis for adjacent removal/addition runs.
public struct IntraLineDiff: Sendable {
    private static let maximumEmphasizedLineByteCount = 4_096

    /// Creates an intra-line diff calculator.
    public init() {}

    /// Pairs the i-th removal with the i-th addition in each adjacent run and
    /// emphasizes their differing middles when the edit is sufficiently small.
    /// - Parameter lines: Hunk body lines in wire order.
    /// - Returns: The same lines with deterministic emphasis ranges applied.
    public func applying(to lines: [DiffLine]) -> [DiffLine] {
        var result = lines
        var index = result.startIndex
        while index < result.endIndex {
            guard result[index].kind == .removal else {
                index += 1
                continue
            }
            let removalStart = index
            while index < result.endIndex, result[index].kind == .removal {
                index += 1
            }
            let additionStart = index
            while index < result.endIndex, result[index].kind == .addition {
                index += 1
            }
            let pairCount = min(additionStart - removalStart, index - additionStart)
            for offset in 0..<pairCount {
                let removalIndex = removalStart + offset
                let additionIndex = additionStart + offset
                let ranges = emphasisRanges(
                    old: result[removalIndex].text,
                    new: result[additionIndex].text
                )
                result[removalIndex] = result[removalIndex]
                    .replacingEmphasisRanges(ranges.old)
                result[additionIndex] = result[additionIndex]
                    .replacingEmphasisRanges(ranges.new)
            }
        }
        return result
    }

    private func emphasisRanges(
        old: String,
        new: String
    ) -> (old: [Range<String.Index>], new: [Range<String.Index>]) {
        guard old.utf8.count <= Self.maximumEmphasizedLineByteCount,
              new.utf8.count <= Self.maximumEmphasizedLineByteCount else {
            return ([], [])
        }
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        let shorterCount = min(oldCharacters.count, newCharacters.count)

        var prefixCount = 0
        while prefixCount < shorterCount,
              oldCharacters[prefixCount] == newCharacters[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < shorterCount - prefixCount,
              oldCharacters[oldCharacters.count - suffixCount - 1]
                == newCharacters[newCharacters.count - suffixCount - 1] {
            suffixCount += 1
        }

        let oldMiddleCount = oldCharacters.count - prefixCount - suffixCount
        let newMiddleCount = newCharacters.count - prefixCount - suffixCount
        let longerLineCount = max(oldCharacters.count, newCharacters.count)
        guard longerLineCount > 0 else { return ([], []) }
        let changedFraction = Double(max(oldMiddleCount, newMiddleCount)) / Double(longerLineCount)
        guard changedFraction <= 0.7 else { return ([], []) }

        return (
            range(in: old, prefixCount: prefixCount, suffixCount: suffixCount),
            range(in: new, prefixCount: prefixCount, suffixCount: suffixCount)
        )
    }

    private func range(
        in text: String,
        prefixCount: Int,
        suffixCount: Int
    ) -> [Range<String.Index>] {
        let lower = text.index(text.startIndex, offsetBy: prefixCount)
        let upper = text.index(text.endIndex, offsetBy: -suffixCount)
        guard lower < upper else { return [] }
        return [lower..<upper]
    }
}
