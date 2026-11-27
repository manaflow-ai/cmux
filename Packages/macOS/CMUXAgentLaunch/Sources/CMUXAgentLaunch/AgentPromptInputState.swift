import Foundation

/// What an agent TUI's input area holds, read from the terminal's screen.
///
/// Used to keep `cmux send` from typing into a prompt a human is halfway
/// through writing, or into an open question or permission dialog.
public enum AgentPromptInputState: Equatable, Sendable {
    /// No agent prompt was recognized on screen.
    case unknown
    /// An agent prompt is visible and empty (placeholder text doesn't count).
    case empty
    /// An agent prompt holds text someone typed.
    case draft(String)
    /// A selection menu or confirmation dialog is waiting for a key.
    case dialog

    /// True when typing into the terminal could disturb a human's input.
    public var blocksTyping: Bool {
        switch self {
        case .draft, .dialog:
            return true
        case .unknown, .empty:
            return false
        }
    }
}

/// One styled run of text in a screen row.
public struct AgentPromptScreenSpan: Equatable, Sendable {
    public var column: Int
    public var text: String
    /// Faint (SGR 2) text. Agent TUIs draw placeholders and hints faint.
    public var faint: Bool

    public init(column: Int, text: String, faint: Bool) {
        self.column = column
        self.text = text
        self.faint = faint
    }
}

/// Recognizes the input areas of Claude Code and Codex on a terminal screen.
///
/// - Claude Code draws its input row as `❯` followed by a no-break space,
///   between two `─` rules; past prompts in the transcript use a plain space,
///   so the input row is the one with the no-break space.
/// - Codex draws `›` followed by a space, with its placeholder in faint text.
///
/// A draft is any non-faint text after the prompt glyph on the input row or
/// its continuation rows. Menus and confirmation dialogs (permission asks,
/// questions, trust prompts) end with a key hint such as "Esc to cancel" or
/// "Press enter to continue". When an input row is on screen, only hints
/// below it count, so an agent's reply that quotes such a hint in the
/// transcript above is not a dialog.
///
/// Both glyphs can appear in other programs' output, so callers should only
/// act on the result for a surface known to run an agent.
extension AgentPromptInputState {
    private static let claudePromptPrefix = "\u{276F}\u{00A0}"
    private static let codexPromptPrefix = "\u{203A} "
    private static let dialogHints = [
        "esc to cancel",
        "esc to go back",
        "press enter to",
        "enter to confirm",
        "enter to select",
    ]
    /// How many non-empty rows at the bottom are searched for dialog hints.
    private static let dialogHintRowWindow = 6

    /// Reads the input state from a screen.
    ///
    /// - Parameter rows: The visible screen, top to bottom; each row's spans
    ///   in column order.
    public init(screenRows rows: [[AgentPromptScreenSpan]]) {
        self = Self.detect(rows: rows)
    }

    private static func detect(rows: [[AgentPromptScreenSpan]]) -> AgentPromptInputState {
        let plainRows = rows.map(plainText)
        let promptRow = plainRows.lastIndex(where: { promptPrefix(in: $0) != nil })

        let hintSearchStart = promptRow.map { $0 + 1 } ?? 0
        let bottomRows = plainRows[hintSearchStart...].reversed()
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(dialogHintRowWindow)
        if bottomRows.contains(where: { row in
            let lowered = row.lowercased()
            return dialogHints.contains { lowered.contains($0) }
        }) {
            return .dialog
        }

        guard let promptRow, let prefix = promptPrefix(in: plainRows[promptRow]) else {
            return .unknown
        }

        var typed = ""
        for index in promptRow..<rows.count {
            var cells = self.cells(rows[index])
            if index == promptRow {
                cells = cellsAfterPrompt(prefix, in: cells)
            } else {
                let plain = plainRows[index].trimmingCharacters(in: .whitespaces)
                if plain.isEmpty || isRule(plain) { break }
                typed += "\n"
            }
            typed += String(cells.filter { !$0.faint }.map(\.character))
        }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}\u{2502}")))
        return trimmed.isEmpty ? .empty : .draft(trimmed)
    }

    // MARK: - Private

    private static func plainText(_ row: [AgentPromptScreenSpan]) -> String {
        var line = ""
        for span in row.sorted(by: { $0.column < $1.column }) {
            let pad = span.column - line.count
            if pad > 0 {
                line += String(repeating: " ", count: pad)
            }
            line += span.text
        }
        return line
    }

    /// The prompt glyph and its separator when `row` is an input row. Claude
    /// may draw a `│` box border before the glyph.
    private static func promptPrefix(in row: String) -> String? {
        var body = Substring(row)
        body = body.drop(while: { $0 == " " })
        if body.hasPrefix("\u{2502}") {
            body = body.dropFirst().drop(while: { $0 == " " })
        }
        if body.hasPrefix(claudePromptPrefix) { return claudePromptPrefix }
        if body.hasPrefix(codexPromptPrefix) { return codexPromptPrefix }
        return nil
    }

    private struct Cell {
        let character: Character
        let faint: Bool
    }

    private static func cells(_ row: [AgentPromptScreenSpan]) -> [Cell] {
        row.sorted(by: { $0.column < $1.column }).flatMap { span in
            span.text.map { Cell(character: $0, faint: span.faint) }
        }
    }

    /// The cells after the prompt glyph and its separator, skipping leading
    /// spaces and a `│` border.
    private static func cellsAfterPrompt(_ prefix: String, in cells: [Cell]) -> [Cell] {
        var index = 0
        while index < cells.count, cells[index].character == " " { index += 1 }
        if index < cells.count, cells[index].character == "\u{2502}" {
            index += 1
            while index < cells.count, cells[index].character == " " { index += 1 }
        }
        for character in prefix {
            guard index < cells.count, cells[index].character == character else { return [] }
            index += 1
        }
        return Array(cells[index...])
    }

    /// A row made only of box-drawing characters: a rule or a box edge.
    private static func isRule(_ row: String) -> Bool {
        row.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) || $0 == " " }
    }
}
