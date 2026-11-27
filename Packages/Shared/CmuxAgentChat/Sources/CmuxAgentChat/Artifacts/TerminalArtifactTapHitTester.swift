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
              Self.cellWidth(of: lines[currentRow]) >= columns,
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

        let normalizedPath = Self.normalizedPath(in: rawPath) ?? token.path
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
            guard let path = Self.normalizedPath(in: raw) else {
                continue
            }
            let leadingTrim = String(raw.prefix(while: Self.leadingTrimCharacters.contains))
            let startColumn = Self.cellWidth(of: String(line[..<tokenStart]))
                + Self.cellWidth(of: leadingTrim)
            result.append(TokenRange(
                rawText: raw,
                path: path,
                startColumn: startColumn,
                endColumn: startColumn + Self.cellWidth(of: path),
                rawEndColumn: Self.cellWidth(of: String(line[..<index]))
            ))
        }
        return result
    }

    /// Transcript prose often names a file without a slash. Keep the gallery's
    /// broad path detector conservative, but make the tapped token itself
    /// actionable when it has an unambiguous filename extension.
    private static func normalizedPath(in raw: String) -> String? {
        if let path = TerminalArtifactPathDetector().tokens(in: raw).first?.path {
            return path
        }

        var candidate = raw.trimmingCharacters(in: bareFilenameLeadingCharacters)
        while let scalar = candidate.unicodeScalars.last,
              bareFilenameTrailingCharacters.contains(scalar) {
            candidate.removeLast()
        }
        guard !candidate.isEmpty,
              !candidate.contains("/"),
              !candidate.contains("@"),
              !candidate.contains("://"),
              !candidate.unicodeScalars.contains(where: forbiddenBareFilenameCharacters.contains)
        else { return nil }

        let path = candidate as NSString
        let pathExtension = path.pathExtension
        let basename = path.deletingPathExtension
        guard !basename.isEmpty,
              !pathExtension.isEmpty,
              candidate.contains(where: { $0.isLetter })
        else { return nil }
        return candidate
    }

    private func leadingContinuation(in line: String) -> Continuation? {
        guard let first = line.first,
              !first.isWhitespace,
              Self.isPathContinuation(first) else {
            return nil
        }
        let text = String(line.prefix(while: { !$0.isWhitespace }))
        guard !text.isEmpty else { return nil }
        return Continuation(text: text, endColumn: Self.cellWidth(of: text))
    }

    private static func cellWidth(of text: String) -> Int {
        text.reduce(0) { $0 + cellWidth(of: $1) }
    }

    private static func cellWidth(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard scalars.contains(where: { !isZeroWidth($0) }) else { return 0 }
        if scalars.contains(where: { isWide($0) || $0.properties.isEmojiPresentation }) {
            return 2
        }
        return 1
    }

    private static func isZeroWidth(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .control, .format:
            return true
        default:
            return false
        }
    }

    private static func isWide(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,
             0x2329...0x232A,
             0x2E80...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x16FE0...0x18DFF,
             0x1AFF0...0x1B2FF,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
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
    private static let bareFilenameLeadingCharacters = CharacterSet(charactersIn: "\"'`([{<")
    private static let bareFilenameTrailingCharacters = CharacterSet(charactersIn: "\"'`)]}>,;:!?.")
    private static let forbiddenBareFilenameCharacters = CharacterSet(charactersIn: "<>\"'\\`")
    private static let pathContinuationCharacters: Set<Character> = [
        "/", ".", "_", "-", "+", "=", "~", "@", "%", ":", "\\",
    ]
}
