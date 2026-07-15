import Foundation

/// Resolves terminal-grid taps to path tokens, including tokens split by soft wrapping.
public struct TerminalArtifactTapHitTester: Sendable {
    /// Creates a terminal artifact tap hit tester.
    public init() {}

    /// Returns the path under a grid cell, stitching continuation rows with no separator.
    ///
    /// `columns` must be the terminal's actual grid width. Row text is insufficient to
    /// infer soft wrapping because the final visible row may be shorter than the grid.
    public func path(in text: String, col: Int, row: Int, columns: Int) -> String? {
        guard col >= 0, row >= 0, columns > 0 else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard row < lines.count else { return nil }

        var bestMatch: StitchedPath?
        for headRow in 0...row {
            for token in tokenRanges(in: lines[headRow]) {
                let candidate = stitchedPath(
                    startingWith: token,
                    at: headRow,
                    lines: lines,
                    columns: columns
                )
                guard candidate.contains(col: col, row: row) else { continue }
                if candidate.segments.count > (bestMatch?.segments.count ?? 0) {
                    bestMatch = candidate
                }
            }
        }
        return bestMatch?.path
    }

    private func stitchedPath(
        startingWith token: TokenRange,
        at row: Int,
        lines: [String],
        columns: Int
    ) -> StitchedPath {
        var rawPath = token.rawText
        var segments = [GridSegment(row: row, startColumn: token.startColumn, endColumn: token.endColumn)]
        var currentRow = row
        var currentRawEndColumn = token.rawEndColumn

        while currentRawEndColumn >= columns,
              lines[currentRow].count >= columns,
              currentRow + 1 < lines.count,
              let continuation = leadingContinuation(in: lines[currentRow + 1]) {
            currentRow += 1
            rawPath += continuation.text
            currentRawEndColumn = continuation.endColumn
            segments.append(GridSegment(
                row: currentRow,
                startColumn: 0,
                endColumn: continuation.endColumn
            ))
        }

        let normalizedPath = TerminalArtifactPathDetector().tokens(in: rawPath).first?.path ?? token.path
        return StitchedPath(path: normalizedPath, segments: segments)
    }

    private func tokenRanges(in line: String) -> [TokenRange] {
        var result: [TokenRange] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
            guard index < line.endIndex else { break }

            let tokenStart = index
            while index < line.endIndex, !line[index].isWhitespace {
                index = line.index(after: index)
            }
            let raw = String(line[tokenStart..<index])
            guard let path = TerminalArtifactPathDetector().tokens(in: raw).first?.path else {
                continue
            }
            let leadingTrim = raw.count - raw.drop(while: Self.leadingTrimCharacters.contains).count
            let startColumn = line.distance(from: line.startIndex, to: tokenStart) + leadingTrim
            result.append(TokenRange(
                rawText: raw,
                path: path,
                startColumn: startColumn,
                endColumn: startColumn + path.count,
                rawEndColumn: line.distance(from: line.startIndex, to: index)
            ))
        }
        return result
    }

    private func leadingContinuation(in line: String) -> Continuation? {
        guard let first = line.first,
              !first.isWhitespace,
              Self.isPathContinuation(first) else {
            return nil
        }
        let text = String(line.prefix(while: { !$0.isWhitespace }))
        guard !text.isEmpty else { return nil }
        return Continuation(text: text, endColumn: text.count)
    }

    private static func isPathContinuation(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || pathContinuationCharacters.contains(character)
    }

    private struct TokenRange {
        let rawText: String
        let path: String
        let startColumn: Int
        let endColumn: Int
        let rawEndColumn: Int
    }

    private struct Continuation {
        let text: String
        let endColumn: Int
    }

    private struct GridSegment {
        let row: Int
        let startColumn: Int
        let endColumn: Int

        func contains(col: Int, row: Int) -> Bool {
            self.row == row && col >= startColumn && col < endColumn
        }
    }

    private struct StitchedPath {
        let path: String
        let segments: [GridSegment]

        func contains(col: Int, row: Int) -> Bool {
            segments.contains { $0.contains(col: col, row: row) }
        }
    }

    private static let leadingTrimCharacters: Set<Character> = ["\"", "'", "`", "(", "[", "{", "<"]
    private static let pathContinuationCharacters: Set<Character> = [
        "/", ".", "_", "-", "+", "=", "~", "@", "%", ":", "\\",
    ]
}
