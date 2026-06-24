import Foundation

/// One displayable row of a session transcript preview.
///
/// A single `SessionTranscriptTurn` may be split into several rows when its text
/// exceeds the per-row character budget; `isContinuation` marks every row after
/// the first split of a turn. Rows are produced by `rows(from:)`, which performs
/// the chunking on whitespace/newline boundaries near the budget.
public struct SessionTranscriptDisplayRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let role: SessionTranscriptRole
    public let text: String
    public let isContinuation: Bool

    public init(id: String, role: SessionTranscriptRole, text: String, isContinuation: Bool) {
        self.id = id
        self.role = role
        self.text = text
        self.isContinuation = isContinuation
    }

    private static let chunkCharacterLimit = 5_000

    /// Flatten parsed turns into display rows, chunking oversized turns.
    public static func rows(from turns: [SessionTranscriptTurn]) -> [SessionTranscriptDisplayRow] {
        turns.flatMap { turn in
            chunks(for: turn.text).enumerated().map { offset, chunk in
                SessionTranscriptDisplayRow(
                    id: "\(turn.id)-\(offset)",
                    role: turn.role,
                    text: chunk,
                    isContinuation: offset > 0
                )
            }
        }
    }

    private static func chunks(for text: String) -> [String] {
        guard text.count > chunkCharacterLimit else {
            return [text]
        }
        var output: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let rawEnd = text.index(
                start,
                offsetBy: chunkCharacterLimit,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            let end = preferredBreak(in: text, from: start, rawEnd: rawEnd)
            output.append(String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = end
            while start < text.endIndex, text[start].isWhitespace {
                start = text.index(after: start)
            }
        }
        return output.filter { !$0.isEmpty }
    }

    private static func preferredBreak(
        in text: String,
        from start: String.Index,
        rawEnd: String.Index
    ) -> String.Index {
        guard rawEnd < text.endIndex else {
            return text.endIndex
        }
        let searchStart = text.index(
            rawEnd,
            offsetBy: -min(chunkCharacterLimit / 4, text.distance(from: start, to: rawEnd))
        )
        if let newline = text[searchStart..<rawEnd].lastIndex(of: "\n") {
            return text.index(after: newline)
        }
        if let space = text[searchStart..<rawEnd].lastIndex(where: { $0.isWhitespace }) {
            return text.index(after: space)
        }
        return rawEnd
    }
}
