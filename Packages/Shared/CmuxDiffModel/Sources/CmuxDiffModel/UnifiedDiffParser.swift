/// Parses unified-diff text into hunk and line value models.
public struct UnifiedDiffParser: Sendable {
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
        var rawLines = unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if unifiedDiff.hasSuffix("\n") {
            rawLines.removeLast()
        }
        var hunks: [DiffHunk] = []
        var current: HunkBuilder?
        var oldLine = 0
        var newLine = 0
        var lineID = 0
        var iteration = 0

        for rawLine in rawLines {
            // Cooperative cancellation: callers discard the result of a
            // cancelled load, so bail out of a stale multi-MB parse early
            // instead of allocating the rest of its lines.
            iteration &+= 1
            if iteration % 4096 == 0, Task.isCancelled {
                break
            }
            if let header = HunkHeader(rawLine: rawLine) {
                if let current {
                    hunks.append(current.build())
                }
                oldLine = header.oldStart
                newLine = header.newStart
                current = HunkBuilder(
                    id: hunks.count,
                    header: rawLine,
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount
                )
                continue
            }

            guard var builder = current else {
                continue
            }
            guard let marker = rawLine.first else {
                builder.append(
                    DiffLine(id: lineID, kind: .context, text: "", oldLine: oldLine, newLine: newLine)
                )
                lineID += 1
                oldLine += 1
                newLine += 1
                current = builder
                continue
            }

            let text = String(rawLine.dropFirst())
            switch marker {
            case "+":
                builder.append(DiffLine(id: lineID, kind: .addition, text: text, oldLine: nil, newLine: newLine))
                lineID += 1
                newLine += 1
            case "-":
                builder.append(DiffLine(id: lineID, kind: .deletion, text: text, oldLine: oldLine, newLine: nil))
                lineID += 1
                oldLine += 1
            case " ":
                builder.append(DiffLine(id: lineID, kind: .context, text: text, oldLine: oldLine, newLine: newLine))
                lineID += 1
                oldLine += 1
                newLine += 1
            case "\\":
                break
            default:
                builder.append(
                    DiffLine(id: lineID, kind: .context, text: rawLine, oldLine: oldLine, newLine: newLine)
                )
                lineID += 1
                oldLine += 1
                newLine += 1
            }
            current = builder
        }

        if let current {
            hunks.append(current.build())
        }
        return DiffParseResult(hunks: hunks, isTruncated: isTruncated)
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

private struct HunkBuilder {
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

    mutating func append(_ line: DiffLine) {
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
