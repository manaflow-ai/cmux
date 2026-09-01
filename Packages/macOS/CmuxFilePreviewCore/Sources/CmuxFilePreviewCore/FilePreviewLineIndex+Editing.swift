import Foundation

extension FilePreviewLineIndex {
    /// Applies one UTF-16 edit without rebuilding the untouched suffix.
    ///
    /// Line starts before the edit remain in place. Starts covered by the old
    /// range are removed, starts after it receive a lazy range shift, and
    /// newline starts from `replacement` are inserted locally.
    ///
    /// - Parameters:
    ///   - location: UTF-16 offset where the edit starts.
    ///   - oldLength: UTF-16 length replaced by the edit.
    ///   - replacement: Text occupying the edited range after the edit.
    public mutating func applyEdit(
        atUTF16Location location: Int,
        replacingUTF16Length oldLength: Int,
        replacement: String
    ) {
        guard location >= 0,
              oldLength >= 0,
              location <= loadedUTF16Length,
              oldLength <= loadedUTF16Length - location else {
            return
        }

        let replacementLength = replacement.utf16.count
        let end = location + oldLength
        let delta = replacementLength - oldLength

        // Keep a line start at the edit location. A start exactly at the old
        // end is retained as a suffix start so deletion can move it to the new
        // boundary; max() also handles zero-length insertions at line starts.
        let prefixEnd = storage.upperBound(location)
        let suffixStart = max(prefixEnd, storage.lowerBound(end))
        let prefixLast = prefixEnd > 0 ? storage.value(at: prefixEnd - 1) : nil
        let boundaryWasLineStart = storage.value(at: suffixStart) == end
        let replacementEndsInNewline = replacement.utf16.last == 10
        let emptyReplacementKeepsBoundary = replacement.isEmpty
            && location > 0
            && prefixLast == location

        storage.remove(range: prefixEnd..<suffixStart)
        storage.add(delta, toSuffixFrom: prefixEnd)

        // A suffix start that sat exactly at the old end belongs to the line
        // after the edit only when the new text ends in a newline (or an empty
        // edit leaves the preceding newline intact). Otherwise the suffix
        // joins the replacement's final line and its old start is discarded.
        if boundaryWasLineStart,
           !replacementEndsInNewline,
           !emptyReplacementKeepsBoundary,
           prefixEnd < storage.count {
            storage.remove(range: prefixEnd..<(prefixEnd + 1))
        }

        // A deletion ending at a line start can move that suffix start onto
        // the preceding line start. Keep one copy of the boundary.
        if let prefixLast {
            var duplicateCount = 0
            while prefixEnd + duplicateCount < storage.count,
                  let value = storage.value(at: prefixEnd + duplicateCount),
                  value <= prefixLast {
                duplicateCount += 1
            }
            if duplicateCount > 0 {
                storage.remove(range: prefixEnd..<(prefixEnd + duplicateCount))
            }
        }

        var insertedStarts: [Int] = []
        var index = 0
        for unit in replacement.utf16 {
            if unit == 10 {
                insertedStarts.append(location + index + 1)
            }
            index += 1
        }

        // If the replacement ends in a newline, its final start is the same
        // boundary represented by the first retained suffix start.
        if let lastInserted = insertedStarts.last,
           let suffixValue = storage.value(at: prefixEnd),
           lastInserted == suffixValue {
            insertedStarts.removeLast()
        }
        storage.insert(insertedStarts, at: prefixEnd)
        loadedUTF16Length += delta
    }
}
