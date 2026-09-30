import Foundation

/// Visual strength for a live agent hint marker.
public enum AgentKeyHintRestSpanStyle: Sendable, Equatable {
    case dotted
    case underline
    case none
}

/// One detected clickable span in a live viewport row.
public struct AgentKeyHintRestSpan: Sendable, Equatable {
    public let row: Int
    public let columns: Range<Int>
    public let style: AgentKeyHintRestSpanStyle

    public init(row: Int, columns: Range<Int>, style: AgentKeyHintRestSpanStyle) {
        self.row = row
        self.columns = columns
        self.style = style
    }
}

/// Finds all at-rest markers without scanning scrollback. Ctrl/Alt hints that
/// remain clickable in history are deliberately excluded from this quieter
/// visual treatment.
public func agentKeyHintRestSpans(
    rows: [(row: Int, text: String)],
    agent: AgentKeyHintDetector.Agent,
    viewportAtBottom: Bool,
    cursorRow: Int?,
    style: AgentKeyHintRestSpanStyle
) -> [AgentKeyHintRestSpan] {
    guard style != .none, viewportAtBottom, let cursorRow, cursorRow >= 0 else { return [] }
    let firstLiveRow = max(0, cursorRow - AgentKeyHintLiveRegion.rowsAboveCursor)
    var spans: [AgentKeyHintRestSpan] = []
    let detector = AgentKeyHintDetector(agent: agent)
    for row in rows where row.row >= firstLiveRow {
        let live = AgentKeyHintLiveRegion(viewportAtBottom: true, cursorRow: cursorRow).contains(row: row.row)
        spans.append(contentsOf: detector.hints(in: row.text, inLiveRegion: true).compactMap { hint in
            guard !hint.needsLiveRegion || live else { return nil }
            return AgentKeyHintRestSpan(row: row.row, columns: hint.columns, style: style)
        })
        guard agent == .codex, live else { continue }
        spans.append(contentsOf: CodexActionCommandDetector().commands(in: row.text).map {
            AgentKeyHintRestSpan(row: row.row, columns: $0.columns, style: style)
        })
    }
    return spans
}
