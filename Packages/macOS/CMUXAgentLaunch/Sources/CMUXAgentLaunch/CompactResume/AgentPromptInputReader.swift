/// Reads whether an agent's input line is empty from a styled screen capture.
///
/// The capture is the terminal's active screen as VT text: printable
/// characters plus SGR escape sequences. Claude Code and Codex draw their
/// placeholder and suggested next prompt dimmed (SGR 2, faint), while typed
/// text is drawn at normal intensity, so the line is empty when everything
/// after the prompt glyph is blank or faint. Anything the reader can't place
/// is ``AgentPromptInputState/unknown``, which callers treat as "don't type".
public struct AgentPromptInputReader: Sendable {
    /// The agent whose input line is read.
    public let dialect: AgentCompactResumeDialect

    /// Creates a reader.
    ///
    /// - Parameter dialect: The agent whose input line is read.
    public init(dialect: AgentCompactResumeDialect) {
        self.dialect = dialect
    }

    /// Classifies the input line in a screen capture.
    ///
    /// - Parameter screen: The active screen as VT text.
    /// - Returns: Whether the input line is empty, holds text, or wasn't found.
    public func state(screen: String) -> AgentPromptInputState {
        let lines = AgentPromptStyledLine.parse(screen)
        guard let promptIndex = lines.lastIndex(where: { $0.startsWithGlyph(dialect.promptGlyph) }) else {
            return .unknown
        }
        var input = lines[promptIndex].cells.drop { $0.character != dialect.promptGlyph }.dropFirst()
            .map { $0 }
        if dialect.inputBoxClosesWithRule {
            guard let ruleOffset = lines[(promptIndex + 1)...].firstIndex(where: \.isHorizontalRule) else {
                return .unknown
            }
            for line in lines[(promptIndex + 1)..<ruleOffset] {
                input.append(contentsOf: line.cells)
            }
        }
        let typed = input.contains { !$0.isFaint && !Self.isBlank($0.character) }
        return typed ? .hasText : .empty
    }

    static func isBlank(_ character: Character) -> Bool {
        character.isWhitespace || character == "│"
    }
}
