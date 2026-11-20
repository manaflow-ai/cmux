import Foundation

/// A bounded, one-based file position or line range shared by every file-open surface.
public nonisolated struct FileLineLocation: Equatable, Sendable {
    /// The first line, from 1 through 10,000,000.
    public let line: Int
    /// The optional column on the first line, with the same bounds.
    public let column: Int?
    /// The optional last line, at or after the first line.
    public let endLine: Int?

    /// A line and column a caller already knows (a Find result, a config key's place), clamped to
    /// the bounds.
    public init(line: Int, column: Int = 1) {
        self.line = min(max(1, line), 10_000_000)
        self.column = min(max(1, column), 10_000_000)
        endLine = nil
    }

    /// Parses `42`, `42:7` or `42-50`; signs, whitespace and non-ASCII digits are refused.
    public init?(_ argument: String) {
        guard argument.utf8.count <= 24 else { return nil }
        let parts = argument.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.map(String.init).joined(separator: argument.contains(":") ? ":" : "-") == argument,
              let line = Int(parts[0]), (1...10_000_000).contains(line) else { return nil }
        let second = parts.count == 2 ? Int(parts[1]) : nil
        if parts.count == 2, second == nil { return nil }
        if let second, !(1...10_000_000).contains(second) { return nil }
        if argument.contains("-"), let second, second < line { return nil }
        self.line = line
        column = argument.contains(":") ? second : nil
        endLine = argument.contains("-") ? second : nil
    }

    /// An action's optional `line` argument: a string as ``init(_:)`` reads it, or a whole number.
    /// Revalidated here because some callers bypass the action schema; `invalid` is thrown for a
    /// value that does not parse.
    public static func argument(_ value: ActionValue?, orThrow invalid: @autoclosure () -> any Error) throws
        -> FileLineLocation? {
        guard let value else { return nil }
        let text: String? = switch value {
        case .string(let text): text
        case .int(let number): String(number)
        case .bool, .target: nil
        }
        guard let text, let location = FileLineLocation(text) else { throw invalid() }
        return location
    }

    /// The numeric spelling accepted by CLI, MCP and the reply-link host.
    public var argument: String {
        if let column { return "\(line):\(column)" }
        if let endLine { return "\(line)-\(endLine)" }
        return String(line)
    }
}
