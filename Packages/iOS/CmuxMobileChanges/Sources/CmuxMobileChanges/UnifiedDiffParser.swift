internal import Foundation

/// Parses raw Git unified-diff text into display-ready hunk snapshots.
public struct UnifiedDiffParser: Sendable {
    private struct ParsedHeader {
        let text: String
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let sectionContext: String?
    }

    /// Creates a unified-diff parser.
    public init() {}

    /// Parses and emphasizes a diff on the generic executor.
    ///
    /// Calling this async worker from a main-actor UI flow suspends before the
    /// synchronous parser work begins, keeping large diff parsing off the UI thread.
    ///
    /// - Parameters:
    ///   - unifiedDiff: Raw Git unified-diff output.
    ///   - truncated: Whether the host truncated the raw diff.
    ///   - isBinary: Whether the file is binary.
    ///   - totalLineCount: Number of lines in the full raw diff, when reported.
    /// - Returns: A display-ready immutable document.
    public nonisolated func parseOffMain(
        _ unifiedDiff: String,
        truncated: Bool = false,
        isBinary: Bool = false,
        totalLineCount: Int? = nil
    ) async -> FileDiffDocument {
        parse(
            unifiedDiff,
            truncated: truncated,
            isBinary: isBinary,
            totalLineCount: totalLineCount
        )
    }

    /// Parses a diff and builds its initial row and gutter projection on one worker.
    ///
    /// - Parameters:
    ///   - unifiedDiff: Raw Git unified-diff output.
    ///   - truncated: Whether the host truncated the raw diff.
    ///   - isBinary: Whether the file is binary.
    ///   - totalLineCount: Number of lines in the full raw diff, when reported.
    ///   - contentFingerprint: Working-file revision fingerprint, when reported.
    ///   - fileKind: Change kind controlling hidden-context expansion.
    /// - Returns: A parsed document and display projection ready for publication.
    public nonisolated func parsePresentationOffMain(
        _ unifiedDiff: String,
        truncated: Bool = false,
        isBinary: Bool = false,
        totalLineCount: Int? = nil,
        contentFingerprint: String? = nil,
        fileKind: FileChangeKind
    ) async -> FileDiffPresentation {
        let document = parse(
            unifiedDiff,
            truncated: truncated,
            isBinary: isBinary,
            totalLineCount: totalLineCount,
            contentFingerprint: contentFingerprint
        )
        return FileDiffPresentation.make(
            document: document,
            expansionState: DiffExpansionState(),
            currentFileLines: nil,
            fileKind: fileKind
        )
    }

    /// Parses a raw Git diff with or without file headers.
    /// - Parameters:
    ///   - unifiedDiff: Raw Git unified-diff output.
    ///   - truncated: Whether the host truncated the raw diff.
    ///   - isBinary: Whether the file is binary.
    ///   - totalLineCount: Number of lines in the full raw diff, when reported.
    ///   - contentFingerprint: Working-file revision fingerprint, when reported.
    /// - Returns: A display-ready document. Empty and rename-only diffs contain no hunks.
    public func parse(
        _ unifiedDiff: String,
        truncated: Bool = false,
        isBinary: Bool = false,
        totalLineCount: Int? = nil,
        contentFingerprint: String? = nil
    ) -> FileDiffDocument {
        let loadedLineCount = unifiedDiff.isEmpty
            ? 0
            : unifiedDiff.components(separatedBy: "\n").count
        guard !unifiedDiff.isEmpty, !isBinary else {
            return FileDiffDocument(
                hunks: [],
                truncated: truncated,
                isBinary: isBinary,
                loadedLineCount: loadedLineCount,
                totalLineCount: totalLineCount,
                contentFingerprint: contentFingerprint
            )
        }

        // `String.split(separator: "\n")` treats CRLF as one extended
        // grapheme and therefore does not split it. Foundation's literal
        // separator keeps the content-side `\r` while splitting on `\n`.
        let rawLines = unifiedDiff.components(separatedBy: "\n")
        var hunks: [DiffHunk] = []
        var currentHeader: ParsedHeader?
        var currentLines: [DiffLine] = []
        var oldNumber = 0
        var newNumber = 0

        for rawLine in rawLines {
            if let parsed = parseHeader(rawLine) {
                appendHunk(header: currentHeader, lines: currentLines, to: &hunks)
                currentHeader = parsed
                currentLines = []
                oldNumber = parsed.oldStart
                newNumber = parsed.newStart
                continue
            }
            guard currentHeader != nil else {
                // Optional diff/index/mode/rename/---/+++ headers are metadata;
                // rename-only and binary diffs therefore naturally produce no hunks.
                continue
            }
            if rawLine == "\\ No newline at end of file" ||
                rawLine == "\\ No newline at end of file\r" {
                currentLines.append(DiffLine(
                    kind: .noNewlineMarker,
                    text: "",
                    oldNumber: nil,
                    newNumber: nil
                ))
                continue
            }
            guard let prefix = rawLine.first else {
                // A trailing newline produces an empty split component. Real
                // empty hunk lines still carry a diff prefix (`+`, `-`, or space).
                continue
            }
            let text = String(rawLine.dropFirst())
            switch prefix {
            case " ":
                currentLines.append(DiffLine(
                    kind: .context,
                    text: text,
                    oldNumber: oldNumber,
                    newNumber: newNumber
                ))
                oldNumber += 1
                newNumber += 1
            case "+":
                currentLines.append(DiffLine(
                    kind: .addition,
                    text: text,
                    oldNumber: nil,
                    newNumber: newNumber
                ))
                newNumber += 1
            case "-":
                currentLines.append(DiffLine(
                    kind: .removal,
                    text: text,
                    oldNumber: oldNumber,
                    newNumber: nil
                ))
                oldNumber += 1
            default:
                continue
            }
        }
        appendHunk(header: currentHeader, lines: currentLines, to: &hunks)
        return FileDiffDocument(
            hunks: hunks,
            truncated: truncated,
            isBinary: isBinary,
            loadedLineCount: loadedLineCount,
            totalLineCount: totalLineCount,
            contentFingerprint: contentFingerprint
        )
    }

    private func appendHunk(
        header: ParsedHeader?,
        lines: [DiffLine],
        to hunks: inout [DiffHunk]
    ) {
        guard let header else { return }
        let emphasized = applyingIntraLineEmphasis(to: lines)
        hunks.append(DiffHunk(
            header: DiffLine(
                kind: .hunkHeader,
                text: header.text,
                oldNumber: nil,
                newNumber: nil
            ),
            oldStart: header.oldStart,
            oldCount: header.oldCount,
            newStart: header.newStart,
            newCount: header.newCount,
            sectionContext: header.sectionContext,
            lines: emphasized
        ))
    }

    /// Keeps Git metadata markers in display order without breaking the
    /// adjacent removal/addition runs used for intra-line emphasis.
    private func applyingIntraLineEmphasis(to lines: [DiffLine]) -> [DiffLine] {
        let contentIndices = lines.indices.filter { lines[$0].kind != .noNewlineMarker }
        let emphasizedContent = IntraLineDiff().applying(to: contentIndices.map { lines[$0] })
        var result = lines
        for (index, emphasizedLine) in zip(contentIndices, emphasizedContent) {
            result[index] = emphasizedLine
        }
        return result
    }

    private func parseHeader(_ line: String) -> ParsedHeader? {
        guard line.hasPrefix("@@") else { return nil }
        let signatureStart = line.index(line.startIndex, offsetBy: 2)
        guard let closingRange = line.range(
            of: "@@",
            range: signatureStart..<line.endIndex
        ) else { return nil }
        let signature = line[signatureStart..<closingRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let components = signature.split(whereSeparator: \.isWhitespace)
        guard components.count >= 2,
              let oldCoordinate = coordinate(String(components[0]), prefix: "-"),
              let newCoordinate = coordinate(String(components[1]), prefix: "+") else {
            return nil
        }
        let rawContext = line[closingRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedHeader(
            text: line,
            oldStart: oldCoordinate.start,
            oldCount: oldCoordinate.count,
            newStart: newCoordinate.start,
            newCount: newCoordinate.count,
            sectionContext: rawContext.isEmpty ? nil : rawContext
        )
    }

    private func coordinate(_ token: String, prefix: Character) -> (start: Int, count: Int)? {
        guard token.first == prefix else { return nil }
        let components = token.dropFirst().split(
            separator: ",",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let startToken = components.first,
              let start = Int(startToken) else { return nil }
        let count = components.count == 2 ? Int(components[1]) : 1
        guard let count else { return nil }
        return (start, count)
    }
}
