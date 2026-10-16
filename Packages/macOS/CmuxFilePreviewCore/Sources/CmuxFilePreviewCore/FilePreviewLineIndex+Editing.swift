import Foundation

extension FilePreviewLineIndex {
    /// Applies one UTF-16 edit without rebuilding the untouched suffix.
    ///
    /// Line-break events outside the edit remain in the implicit treap and a
    /// lazy delta moves the suffix. Only small boundary fragments are rebuilt;
    /// edits near the start of a dense document therefore stay logarithmic in
    /// the number of untouched lines.
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

        let oldEnd = location + oldLength
        let replacementLength = replacement.utf16.count
        let delta = replacementLength - oldLength
        let existingCount = storage.count

        // Remove events touched by the old range and include one adjacent
        // event on either side. The neighbors are needed when an edit joins a
        // CR with an LF (or splits an existing CRLF pair).
        var removeStart = storage.firstEnd(after: location)
        var removeEnd = storage.lowerBoundStart(oldEnd)
        if removeStart > 0,
           let previous = storage.lineBreak(at: removeStart - 1),
           previous.offset + previous.kind.length == location {
            removeStart -= 1
        }
        if removeEnd < existingCount,
           let next = storage.lineBreak(at: removeEnd),
           next.offset == oldEnd {
            removeEnd += 1
        }

        // For a zero-length insertion inside a CRLF event, the range search
        // above already includes the containing event. Keep this explicit
        // guard as a contract check for future event-kind changes.
        if oldLength == 0,
           let containing = storage.lineBreak(at: storage.firstEnd(after: location)),
           containing.offset < location,
           location < containing.offset + containing.kind.length {
            let containingIndex = storage.firstEnd(after: location)
            removeStart = min(removeStart, containingIndex)
            removeEnd = max(removeEnd, containingIndex + 1)
        }

        var prefixUnits: [FilePreviewLineBreakUnit] = []
        var suffixUnits: [FilePreviewLineBreakUnit] = []
        if removeStart < removeEnd {
            prefixUnits.reserveCapacity((removeEnd - removeStart) * 2)
            suffixUnits.reserveCapacity((removeEnd - removeStart) * 2)
            for index in removeStart..<removeEnd {
                guard let lineBreak = storage.lineBreak(at: index) else { continue }
                for (unitIndex, rawUnit) in lineBreak.kind.rawUnits.enumerated() {
                    let oldOffset = lineBreak.offset + unitIndex
                    guard oldOffset < location || oldOffset >= oldEnd else { continue }
                    let newOffset = oldOffset < location ? oldOffset : oldOffset + delta
                    if let kind = Self.lineBreakKind(for: rawUnit) {
                        let unit = FilePreviewLineBreakUnit(offset: newOffset, kind: kind)
                        if oldOffset < location {
                            prefixUnits.append(unit)
                        } else {
                            suffixUnits.append(unit)
                        }
                    }
                }
            }
            storage.remove(range: removeStart..<removeEnd)
        }

        storage.add(delta, toSuffixFrom: removeStart)
        let replacementBreaks = FilePreviewLineIndexStorage.lineBreaks(
            in: replacement,
            offset: location
        )
        prefixUnits.append(contentsOf: replacementBreaks)
        prefixUnits.append(contentsOf: suffixUnits)
        storage.insert(
            FilePreviewLineIndexStorage.mergeAdjacentLineBreaks(prefixUnits),
            at: removeStart
        )
        loadedUTF16Length += delta
    }

    private static func lineBreakKind(for rawUnit: UInt16) -> FilePreviewLineBreakKind? {
        switch rawUnit {
        case 0x0A:
            .lineFeed
        case 0x0D:
            .carriageReturn
        case 0x2028:
            .lineSeparator
        case 0x2029:
            .paragraphSeparator
        default:
            nil
        }
    }
}
