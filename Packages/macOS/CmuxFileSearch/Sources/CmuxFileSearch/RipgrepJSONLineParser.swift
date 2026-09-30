import Foundation

/// Parses one line of `rg --json` output.
///
/// ripgrep reports submatch offsets in UTF-8 bytes of the line. Paths and
/// lines arrive as `{"text": ...}` or, when they are not valid UTF-8, as
/// `{"bytes": base64}`. Byte offsets are converted to UTF-16 so AppKit text
/// ranges and editor columns line up with what the user sees.
public struct RipgrepJSONLineParser: Sendable {
    /// UTF-16 units of context kept before a match in a preview.
    public let previewLeadingContext: Int
    /// Upper bound on a stored preview, in UTF-16 units.
    public let previewMaximumLength: Int

    public init(previewLeadingContext: Int = 40, previewMaximumLength: Int = 250) {
        self.previewLeadingContext = previewLeadingContext
        self.previewMaximumLength = previewMaximumLength
    }

    private static let matchPrefix = Array(#"{"type":"match""#.utf8)

    /// The matches on one `match` line, or `nil` for any other event or a
    /// line that does not parse.
    public func parseMatch<Bytes: Collection<UInt8>>(line bytes: Bytes) -> FileSearchFileMatches? {
        guard bytes.starts(with: Self.matchPrefix) else { return nil }
        let data = Data(bytes)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let pathObject = payload["path"] as? [String: Any],
              let path = Self.decodedString(from: pathObject),
              let linesObject = payload["lines"] as? [String: Any],
              let lineNumber = payload["line_number"] as? Int else {
            return nil
        }
        let byteRanges = (payload["submatches"] as? [[String: Any]] ?? []).compactMap { raw -> Range<Int>? in
            guard let start = raw["start"] as? Int, let end = raw["end"] as? Int,
                  start >= 0, end >= start else { return nil }
            return start..<end
        }
        let matches: [FileSearchMatch]
        if let text = linesObject["text"] as? String {
            matches = makeMatches(textLine: text, lineNumber: lineNumber, byteRanges: byteRanges)
        } else if let encoded = linesObject["bytes"] as? String, let decoded = Data(base64Encoded: encoded) {
            matches = makeMatches(lineBytes: Array(decoded), lineNumber: lineNumber, byteRanges: byteRanges)
        } else {
            return nil
        }
        return FileSearchFileMatches(path: path, matches: matches)
    }

    /// Converts byte-offset submatches on a valid UTF-8 line into matches.
    /// Walks the UTF-16 view once, counting each scalar's UTF-8 width, which
    /// is much cheaper than re-encoding a bridged string to bytes.
    func makeMatches(textLine text: String, lineNumber: Int, byteRanges: [Range<Int>]) -> [FileSearchMatch] {
        var units = Array(text.utf16)
        if units.last == 0x0A { units.removeLast() }
        if units.last == 0x0D { units.removeLast() }
        let ranges = Self.sortedRanges(byteRanges)
        let boundaries = Self.sortedBoundaries(ranges)
        var unitOffsets = [Int](repeating: units.count, count: boundaries.count)
        var boundaryIndex = 0
        var byteOffset = 0
        var unitIndex = 0
        while boundaryIndex < boundaries.count, boundaries[boundaryIndex] <= 0 {
            unitOffsets[boundaryIndex] = 0
            boundaryIndex += 1
        }
        while unitIndex < units.count, boundaryIndex < boundaries.count {
            let unit = units[unitIndex]
            if unit < 0x80 {
                byteOffset += 1
                unitIndex += 1
            } else if unit < 0x800 {
                byteOffset += 2
                unitIndex += 1
            } else if UTF16.isLeadSurrogate(unit), unitIndex + 1 < units.count,
                      UTF16.isTrailSurrogate(units[unitIndex + 1]) {
                byteOffset += 4
                unitIndex += 2
            } else {
                byteOffset += 3
                unitIndex += 1
            }
            while boundaryIndex < boundaries.count, boundaries[boundaryIndex] <= byteOffset {
                unitOffsets[boundaryIndex] = unitIndex
                boundaryIndex += 1
            }
        }
        return makeMatches(units: &units, lineNumber: lineNumber, ranges: ranges, boundaries: boundaries, unitOffsets: unitOffsets)
    }

    /// Converts byte-offset submatches on a line that is not valid UTF-8.
    /// Each gap between boundaries decodes on its own, so every invalid
    /// sequence becomes one U+FFFD in both the offsets and the rendered line.
    func makeMatches(lineBytes rawLineBytes: [UInt8], lineNumber: Int, byteRanges: [Range<Int>]) -> [FileSearchMatch] {
        var lineBytes = rawLineBytes
        if lineBytes.last == 0x0A { lineBytes.removeLast() }
        if lineBytes.last == 0x0D { lineBytes.removeLast() }
        let byteCount = lineBytes.count
        let ranges = Self.sortedRanges(byteRanges)
        let boundaries = Self.sortedBoundaries(ranges).map { min($0, byteCount) }
        var unitOffsets: [Int] = []
        var units: [UInt16] = []
        units.reserveCapacity(byteCount)
        var cursor = 0
        for boundary in boundaries {
            if boundary > cursor {
                units.append(contentsOf: String(decoding: lineBytes[cursor..<boundary], as: UTF8.self).utf16)
                cursor = boundary
            }
            unitOffsets.append(units.count)
        }
        if cursor < byteCount {
            units.append(contentsOf: String(decoding: lineBytes[cursor..<byteCount], as: UTF8.self).utf16)
        }
        return makeMatches(units: &units, lineNumber: lineNumber, ranges: ranges, boundaries: boundaries, unitOffsets: unitOffsets)
    }

    /// Ranges in line order. A line with no submatches (possible for some
    /// empty patterns) still yields one match at column 1 so the file is listed.
    private static func sortedRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        ranges.isEmpty ? [0..<0] : ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func sortedBoundaries(_ ranges: [Range<Int>]) -> [Int] {
        var boundaries: [Int] = []
        boundaries.reserveCapacity(ranges.count * 2)
        for range in ranges {
            boundaries.append(range.lowerBound)
            boundaries.append(range.upperBound)
        }
        boundaries.sort()
        return boundaries
    }

    private func makeMatches(
        units: inout [UInt16],
        lineNumber: Int,
        ranges: [Range<Int>],
        boundaries: [Int],
        unitOffsets: [Int]
    ) -> [FileSearchMatch] {
        // Tabs render as one space so previews stay on one visual line
        // without shifting the offsets.
        for index in units.indices where units[index] == 0x09 { units[index] = 0x20 }
        let firstContent = units.firstIndex { $0 != 0x20 } ?? units.count
        func unitOffset(forByte byte: Int) -> Int {
            // Binary search over the sorted boundaries of this line.
            var low = 0
            var high = boundaries.count - 1
            while low < high {
                let mid = (low + high) / 2
                if boundaries[mid] < byte { low = mid + 1 } else { high = mid }
            }
            return unitOffsets[low]
        }
        return ranges.map { range in
            let start = unitOffset(forByte: range.lowerBound)
            let end = max(start, unitOffset(forByte: range.upperBound))
            let preview = makePreview(units: units, firstContent: firstContent, matchStart: start, matchEnd: end)
            return FileSearchMatch(
                lineNumber: lineNumber,
                column: start + 1,
                length: end - start,
                preview: preview.text,
                previewMatchRange: preview.matchRange
            )
        }
    }

    private func makePreview(
        units: [UInt16],
        firstContent: Int,
        matchStart: Int,
        matchEnd: Int
    ) -> (text: String, matchRange: Range<Int>) {
        var windowStart: Int
        let elided: Bool
        if matchStart - firstContent <= previewLeadingContext {
            windowStart = min(firstContent, matchStart)
            elided = false
        } else {
            windowStart = matchStart - previewLeadingContext
            elided = true
        }
        windowStart = Self.adjustedToScalarBoundary(windowStart, in: units)
        // Keep a long match visible up to twice the preview budget; the
        // stored string stays bounded however long the line or match is.
        let budgetEnd = windowStart + previewMaximumLength
        var windowEnd = min(units.count, max(budgetEnd, min(matchEnd, budgetEnd + previewMaximumLength)))
        windowEnd = Self.adjustedToScalarBoundary(windowEnd, in: units)
        while windowEnd > max(windowStart, matchEnd), units[windowEnd - 1] == 0x20 { windowEnd -= 1 }

        let prefix = elided ? "\u{2026}" : ""
        let body = String(decoding: units[windowStart..<windowEnd], as: UTF16.self)
        let shift = prefix.utf16.count - windowStart
        let lower = min(max(matchStart + shift, prefix.utf16.count), prefix.utf16.count + (windowEnd - windowStart))
        let upper = min(max(matchEnd + shift, lower), prefix.utf16.count + (windowEnd - windowStart))
        return (prefix + body, lower..<upper)
    }

    /// Moves an offset that lands between a surrogate pair back to the pair's start.
    private static func adjustedToScalarBoundary(_ offset: Int, in units: [UInt16]) -> Int {
        guard offset > 0, offset < units.count else { return offset }
        return UTF16.isTrailSurrogate(units[offset]) ? offset - 1 : offset
    }

    private static func decodedString(from object: [String: Any]) -> String? {
        if let text = object["text"] as? String {
            return text
        }
        guard let encoded = object["bytes"] as? String,
              let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
