/// Parses unified-diff text into hunk and line value models.
public struct UnifiedDiffParser: Sendable {
    private static let maximumHunkCount = 2_000
    private static let maximumLineCountPerHunk = 2_000
    private static let maximumTotalLineCount = 20_000
    private static let maximumDisplayedLineUTF8Bytes = 8 * 1024

    /// Creates a unified-diff parser.
    public init() {}

    /// Parses unified diff text.
    ///
    /// File headers, rename metadata, binary notices, and other non-hunk lines
    /// are ignored. Malformed hunk headers are skipped instead of failing the
    /// whole parse, so binary or empty diffs produce an empty hunk list.
    ///
    /// - Parameters:
    ///   - unifiedDiff: Raw unified diff text.
    ///   - isTruncated: Whether the producer capped `unifiedDiff`.
    /// - Returns: Parsed hunks plus the truncation flag.
    public func parse(_ unifiedDiff: String, isTruncated: Bool = false) -> DiffParseResult {
        guard !Task.isCancelled else {
            return DiffParseResult(hunks: [], isTruncated: isTruncated)
        }
        var hunks: [DiffHunk] = []
        var current: HunkBuilder?
        var oldLine = 0
        var newLine = 0
        var lineID = 0
        var iteration = 0
        var currentHunkLineCount = 0
        var totalLineCount = 0
        var parserTruncated = false

        for rawLine in UnifiedDiffLineSequence(unifiedDiff) {
            // Cooperative cancellation: callers discard the result of a
            // cancelled load, so bail out of a stale multi-MB parse early
            // instead of allocating the rest of its lines.
            iteration &+= 1
            if iteration % 4096 == 0, Task.isCancelled {
                break
            }
            if rawLine.hasPrefix("diff --git ") {
                if let completedHunk = current {
                    hunks.append(completedHunk.build())
                }
                current = nil
                currentHunkLineCount = 0
                continue
            }
            if let header = HunkHeader(rawLine: rawLine) {
                if let current {
                    hunks.append(current.build())
                }
                current = nil
                guard totalLineCount < Self.maximumTotalLineCount else {
                    parserTruncated = true
                    break
                }
                guard hunks.count < Self.maximumHunkCount else {
                    parserTruncated = true
                    break
                }
                oldLine = header.oldStart
                newLine = header.newStart
                currentHunkLineCount = 0
                let displayedHeader = Self.cappedDisplayText(rawLine)
                parserTruncated = parserTruncated || displayedHeader.wasCapped
                current = HunkBuilder(
                    id: hunks.count,
                    header: displayedHeader.text,
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount
                )
                continue
            }

            guard let builder = current else {
                continue
            }
            guard totalLineCount < Self.maximumTotalLineCount else {
                parserTruncated = true
                break
            }
            if currentHunkLineCount >= Self.maximumLineCountPerHunk {
                parserTruncated = true
                continue
            }
            guard let marker = rawLine.first else {
                builder.append(
                    DiffLine(id: lineID, kind: .context, text: "", oldLine: oldLine, newLine: newLine)
                )
                lineID += 1
                currentHunkLineCount += 1
                totalLineCount += 1
                oldLine += 1
                newLine += 1
                continue
            }

            let displayedText = Self.cappedDisplayText(rawLine.dropFirst())
            parserTruncated = parserTruncated || displayedText.wasCapped
            switch marker {
            case "+":
                builder.append(DiffLine(id: lineID, kind: .addition, text: displayedText.text, oldLine: nil, newLine: newLine))
                lineID += 1
                newLine += 1
            case "-":
                builder.append(DiffLine(id: lineID, kind: .deletion, text: displayedText.text, oldLine: oldLine, newLine: nil))
                lineID += 1
                oldLine += 1
            case " ":
                builder.append(DiffLine(id: lineID, kind: .context, text: displayedText.text, oldLine: oldLine, newLine: newLine))
                lineID += 1
                oldLine += 1
                newLine += 1
            case "\\":
                break
            default:
                let displayedRawLine = Self.cappedDisplayText(rawLine)
                parserTruncated = parserTruncated || displayedRawLine.wasCapped
                builder.append(
                    DiffLine(id: lineID, kind: .context, text: displayedRawLine.text, oldLine: oldLine, newLine: newLine)
                )
                lineID += 1
                oldLine += 1
                newLine += 1
            }
            if marker != "\\" {
                currentHunkLineCount += 1
                totalLineCount += 1
            }
        }

        if let current {
            hunks.append(current.build())
        }
        return DiffParseResult(hunks: hunks, isTruncated: isTruncated || parserTruncated)
    }

    /// Bounds every retained row before it reaches SwiftUI text layout or an
    /// accessibility label. The cut stays on a Unicode-scalar boundary.
    private static func cappedDisplayText<T: StringProtocol>(_ source: T) -> (text: String, wasCapped: Bool) {
        let text = String(source)
        let utf8 = text.utf8
        guard let limit = utf8.index(
            utf8.startIndex,
            offsetBy: maximumDisplayedLineUTF8Bytes,
            limitedBy: utf8.endIndex
        ), limit != utf8.endIndex else {
            return (text, false)
        }
        var scalarBoundary = limit
        while String.Index(scalarBoundary, within: text) == nil {
            scalarBoundary = utf8.index(before: scalarBoundary)
        }
        let stringBoundary = String.Index(scalarBoundary, within: text) ?? text.startIndex
        return (String(text[..<stringBoundary]), true)
    }
}

/// Iterates UTF-8 lines without first allocating an array proportional to the
/// source line count. Byte scanning keeps CRLF from becoming one Swift grapheme.
private struct UnifiedDiffLineSequence: Sequence, IteratorProtocol {
    private var remaining: Substring.UTF8View

    init(_ source: String) {
        remaining = source[...].utf8
    }

    mutating func next() -> String? {
        guard !remaining.isEmpty else { return nil }
        guard let newline = remaining.firstIndex(of: 0x0A) else {
            defer { remaining = remaining[remaining.endIndex...] }
            return String(decoding: remaining, as: UTF8.self)
        }
        let bytes = remaining[..<newline]
        remaining = remaining[remaining.index(after: newline)...]
        if bytes.last == 0x0D {
            return String(decoding: bytes.dropLast(), as: UTF8.self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct HunkHeader {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int

    init?(rawLine: String) {
        guard rawLine.hasPrefix("@@ ") else { return nil }
        let parts = rawLine.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "@@" else { return nil }
        guard let oldRange = Self.parseRange(String(parts[1]), prefix: "-"),
              let newRange = Self.parseRange(String(parts[2]), prefix: "+") else {
            return nil
        }
        oldStart = oldRange.start
        oldCount = oldRange.count
        newStart = newRange.start
        newCount = newRange.count
    }

    private static func parseRange(_ raw: String, prefix: String) -> (start: Int, count: Int)? {
        guard raw.hasPrefix(prefix) else { return nil }
        let body = raw.dropFirst(prefix.count)
        let pieces = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let startRaw = pieces.first, let start = Int(startRaw) else { return nil }
        let count = pieces.count == 2 ? Int(pieces[1]) : 1
        guard let count else { return nil }
        return (start, count)
    }
}

/// Reference semantics keep one mutable line buffer per hunk. Copying a value
/// builder on every parsed row would repeatedly trigger Array copy-on-write.
private final class HunkBuilder {
    let id: Int
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    private var lines: [DiffLine] = []

    init(id: Int, header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
    }

    func append(_ line: DiffLine) {
        lines.append(line)
    }

    func build() -> DiffHunk {
        DiffHunk(
            id: id,
            header: header,
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            lines: lines
        )
    }
}
