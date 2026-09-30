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

/// The agent family represented by a detected prompt.
public enum AgentPromptAgentKind: String, Equatable, Sendable {
    /// Anthropic's Claude Code terminal interface.
    case claude
    /// OpenAI's Codex terminal interface.
    case codex
}

/// A screen observation used by commands that submit text to an agent.
///
/// The input state retains the draft and dialog guard from ``AgentPromptInputState``.
/// The additional flags describe transient UI that changes which key submits a
/// message (for example, Codex's busy queue affordance).
public struct AgentPromptSubmissionSnapshot: Equatable, Sendable {
    /// The detected input, dialog, or unknown state.
    public let state: AgentPromptInputState
    /// The agent family inferred from its prompt, when one is visible.
    public let agentKind: AgentPromptAgentKind?
    /// True when an agent is processing a turn and offers a queue action.
    public let busy: Bool
    /// True when the screen reports that a message has been queued.
    public let queued: Bool
    /// True when an agent is showing slash-command suggestions.
    public let slashCommandPopup: Bool

    /// Creates a snapshot from styled terminal rows.
    ///
    /// - Parameter screenRows: Visible rows from top to bottom. Faint spans are
    ///   treated as placeholders and are excluded from drafts.
    public init(screenRows: [[AgentPromptScreenSpan]]) {
        let result = Self.detect(rows: screenRows)
        state = result.state
        agentKind = result.agentKind
        busy = result.busy
        queued = result.queued
        slashCommandPopup = result.slashCommandPopup
    }

    /// Creates a conservative snapshot from plain terminal text.
    ///
    /// ANSI styling is removed, so only well-known placeholder phrases are
    /// treated as empty. Unknown text following a prompt remains a draft.
    ///
    /// - Parameter screenText: Visible screen text, with one row per line.
    public init(screenText: String) {
        let rows = screenText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { [AgentPromptScreenSpan(column: 0, text: Self.stripANSI(String($0).replacingOccurrences(of: "\r", with: "")), faint: false)] }
        self.init(screenRows: rows)
    }

    /// Alias for callers that use an `is` prefix for state flags.
    public var isBusy: Bool { busy }
    /// Alias for callers that use an `is` prefix for state flags.
    public var isQueued: Bool { queued }
    /// Alias for callers that use a visibility suffix for popup state.
    public var hasSlashCommandPopup: Bool { slashCommandPopup }
    /// Alias for callers that call the detected family the kind.
    public var kind: AgentPromptAgentKind? { agentKind }
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
    /// Reads the input state from a screen.
    ///
    /// - Parameter rows: The visible screen, top to bottom; each row's spans
    ///   in column order.
    public init(screenRows rows: [[AgentPromptScreenSpan]]) {
        self = AgentPromptSubmissionSnapshot(screenRows: rows).state
    }

}

private extension AgentPromptSubmissionSnapshot {
    static let claudePromptPrefix = "\u{276F}\u{00A0}"
    static let codexPromptPrefix = "\u{203A} "
    static let dialogHints = [
        "esc to cancel",
        "esc to go back",
        "press enter to",
        "enter to confirm",
        "enter to select",
    ]
    /// How many non-empty rows at the bottom are searched for dialog hints.
    static let dialogHintRowWindow = 6

    struct DetectionResult {
        let state: AgentPromptInputState
        let agentKind: AgentPromptAgentKind?
        let busy: Bool
        let queued: Bool
        let slashCommandPopup: Bool
    }

    static func detect(rows: [[AgentPromptScreenSpan]]) -> DetectionResult {
        let plainRows = rows.map(plainText)
        let promptRow = plainRows.lastIndex(where: { promptPrefix(in: $0) != nil })
        let detectedKind = promptRow.flatMap { self.agentKind(for: plainRows[$0]) }
            ?? inferredAgentKind(from: plainRows)

        let hintSearchStart = promptRow.map { $0 + 1 } ?? 0
        let bottomRows = Array(plainRows[hintSearchStart...].reversed()
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(dialogHintRowWindow))
        let slashCommandPopup = isSlashCommandPopup(
            plainRows: plainRows,
            promptRow: promptRow,
            bottomRows: bottomRows
        )
        let hasDialogHint = bottomRows.contains(where: { row in
            let lowered = row.lowercased()
            return dialogHints.contains { lowered.contains($0) }
        })
        if hasDialogHint || slashCommandPopup {
            return DetectionResult(
                state: .dialog,
                agentKind: detectedKind,
                busy: isBusy(plainRows),
                queued: isQueued(plainRows),
                slashCommandPopup: slashCommandPopup
            )
        }

        guard let promptRow, let prefix = promptPrefix(in: plainRows[promptRow]) else {
            return DetectionResult(
                state: .unknown,
                agentKind: detectedKind,
                busy: isBusy(plainRows),
                queued: isQueued(plainRows),
                slashCommandPopup: slashCommandPopup
            )
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
        let state: AgentPromptInputState
        if trimmed.isEmpty || isPlaceholder(trimmed, kind: detectedKind) {
            state = .empty
        } else {
            state = .draft(trimmed)
        }
        return DetectionResult(
            state: state,
            agentKind: detectedKind,
            busy: isBusy(plainRows),
            queued: isQueued(plainRows),
            slashCommandPopup: slashCommandPopup
        )
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

    private static func agentKind(for row: String) -> AgentPromptAgentKind? {
        guard let prefix = promptPrefix(in: row) else { return nil }
        return prefix == claudePromptPrefix ? .claude : .codex
    }

    private static func inferredAgentKind(from rows: [String]) -> AgentPromptAgentKind? {
        let text = rows.joined(separator: "\n").lowercased()
        if text.contains("ask codex") || text.contains("codex") { return .codex }
        if text.contains("claude code") { return .claude }
        return nil
    }

    private static func isBusy(_ rows: [String]) -> Bool {
        let markers = [
            "working", "thinking", "generating", "processing",
            "esc to interrupt", "press esc to interrupt", "ctrl+c to interrupt",
        ]
        return rows.contains { row in
            let lowered = row.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return markers.contains { lowered.contains($0) }
        }
    }

    private static func isQueued(_ rows: [String]) -> Bool {
        rows.contains { row in
            let lowered = row.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowered == "queued" || lowered.hasPrefix("queued ")
                || lowered.contains("in queue") || lowered.contains("message queued")
        }
    }

    private static func isSlashCommandPopup(
        plainRows: [String],
        promptRow: Int?,
        bottomRows: [String]
    ) -> Bool {
        guard let promptRow else { return false }
        let promptBody = plainRows[promptRow]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let promptText = String(promptBody.dropFirst(promptPrefix(in: plainRows[promptRow])?.count ?? 0))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSlashOption = plainRows.dropFirst(promptRow + 1).contains { row in
            row.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
        }
        guard hasSlashOption else { return false }
        let hasSelectionHint = bottomRows.contains { row in
            let lowered = row.lowercased()
            return lowered.contains("enter to select") || lowered.contains("tab to select")
                || lowered.contains("esc to cancel")
        }
        return hasSelectionHint || promptText.hasPrefix("/")
    }

    private static func isPlaceholder(_ text: String, kind: AgentPromptAgentKind?) -> Bool {
        guard kind == .codex else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "ask codex to do anything",
            "ask codex anything",
            "ask codex to do something",
        ].contains(normalized)
    }

    private static func stripANSI(_ text: String) -> String {
        var output = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\u{001B}" else {
                output.append(character)
                continue
            }
            guard iterator.next() == "[" else { continue }
            while let control = iterator.next() {
                if ("@"..."~").contains(control) { break }
            }
        }
        return output
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
