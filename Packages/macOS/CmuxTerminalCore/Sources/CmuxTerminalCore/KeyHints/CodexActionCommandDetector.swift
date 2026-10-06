public import Foundation

/// A deliberately narrow command that cmux may offer as a clickable action.
public struct CodexActionCommand: Sendable, Equatable {
    public let command: String
    public let columns: Range<Int>
    public init(command: String, columns: Range<Int>) { self.command = command; self.columns = columns }
}

/// Detects only a complete, allowlisted Codex action footer. Shell examples and
/// prose remain inert because the whole trimmed row must match.
public struct CodexActionCommandDetector: Sendable {
    public init() {}
    public func command(in line: String, atColumn column: Int) -> CodexActionCommand? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let statuses = [
            "Goal paused",
            "Goal stalled",
            "Goal hit usage limits"
        ]
        guard let status = statuses.first(where: { text == "\($0) (/goal resume)" }) else {
            return nil
        }
        let lineStart = line.firstIndex(where: { !$0.isWhitespace }).map {
            line.distance(from: line.startIndex, to: $0)
        } ?? 0
        let start = lineStart + status.count + 2
        let end = start + "/goal resume".count
        guard (start..<end).contains(column) else { return nil }
        return CodexActionCommand(command: "/goal resume", columns: start..<end)
    }
}
