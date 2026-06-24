import Foundation

/// Extracts the agent's in-progress prose from a snapshot of the terminal's
/// rendered screen, for the live streaming preview.
///
/// The agent CLIs paint their turn with a cursor-addressed TUI and never write
/// token-level deltas to their JSONL transcript, so the only token-grained
/// source of a streaming answer is the emulated screen grid. This extractor is
/// deliberately conservative and **best-effort**: the preview it returns is
/// always superseded by the authoritative JSONL line when the turn settles, so
/// a transient mis-extraction self-corrects within one turn. It returns `nil`
/// whenever it cannot confidently locate an actively-streaming answer, which the
/// caller treats as "show nothing" rather than guess.
///
/// Strategy (the "spinner anchor"): while a turn is in flight the agent renders
/// a working/status line carrying an elapsed timer (`(4s · ↓ 21 tokens)`,
/// `Thinking… (esc to interrupt)`). That line sits directly below the streaming
/// answer and above the input box, so it is a stable local landmark that needs
/// no knowledge of the prompt text or the input-box format. Everything at or
/// below it is chrome; the contiguous text block immediately above it, up to the
/// previous committed block, is the in-progress answer.
public struct AgentChatProseScreenExtractor: Sendable {
    /// Hard cap on how many lines above the anchor are considered, so a screen
    /// with no committed-block boundary can't fold the whole scrollback into one
    /// preview.
    private static let maxAnswerLines = 200

    public init() {}

    /// Extracts the current streaming answer from rendered screen rows.
    ///
    /// - Parameters:
    ///   - lines: Rendered screen rows, top to bottom (e.g. a render-grid
    ///     snapshot's plain rows). Trailing whitespace per row is ignored.
    ///   - agentKind: Selects per-agent boundary markers.
    /// - Returns: The cleaned in-progress prose, or `nil` when no actively
    ///   streaming answer is present.
    public func extract(lines: [String], agentKind: ChatAgentKind) -> String? {
        let rows = lines.map { Self.trimTrailing($0) }
        guard let anchor = Self.statusLineIndex(in: rows) else { return nil }
        guard anchor > 0 else { return nil }

        let lowerBound = max(0, anchor - Self.maxAnswerLines)
        var collected: [String] = []
        var index = anchor - 1
        while index >= lowerBound {
            let row = rows[index]
            if Self.isBoundary(row, agentKind: agentKind) { break }
            collected.append(row)
            index -= 1
        }
        collected.reverse()

        // Strip a leading committed-block bullet if the answer just committed
        // on screen (e.g. Claude prefixes a finalized block with "⏺ ").
        if let first = collected.first {
            collected[0] = Self.strippingLeadingBullet(first, agentKind: agentKind)
        }

        let cleaned = Self.collapsingBlankRuns(collected)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Anchoring

    /// The highest-indexed row that looks like the agent's working/status line
    /// (an elapsed-time timer, or an explicit interrupt hint). Scanning from the
    /// bottom skips the input box and footer, which always sit below it.
    static func statusLineIndex(in rows: [String]) -> Int? {
        for index in stride(from: rows.count - 1, through: 0, by: -1) {
            if isStatusLine(rows[index]) { return index }
        }
        return nil
    }

    /// Whether a row is the agent's working/status line. Matched on stable
    /// signals rather than the (randomized, localized) gerund or spinner glyph:
    /// an `(<n>s` elapsed timer, or an explicit "esc to interrupt" hint.
    static func isStatusLine(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.contains("esc to interrupt") || lower.contains("esc to cancel") {
            return true
        }
        // An elapsed timer like "(4s", "(12s ", "(1m05s" rendered on the status
        // line. Require a leading spinner glyph or the token/throughput markers
        // Claude shows alongside it, so a parenthesized "(3s ...)" inside prose
        // is not mistaken for the anchor.
        guard trimmed.contains(where: { Self.spinnerGlyphs.contains($0) })
            || lower.contains("token")
            || trimmed.contains("↓") || trimmed.contains("↑")
        else { return false }
        return Self.containsElapsedTimer(trimmed)
    }

    /// Whether the row contains an elapsed-time token of the form `(<digits>s`
    /// or `(<digits>m<digits>s`, e.g. `(4s`, `(12s`, `(1m05s`. Hand-scanned to
    /// avoid a regex literal, whose `/.../ ` parse is ambiguous next to division.
    static func containsElapsedTimer(_ text: String) -> Bool {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index] == "(" else { index += 1; continue }
            var cursor = index + 1
            var sawDigits = false
            // digits
            while cursor < chars.count, chars[cursor].isNumber { cursor += 1; sawDigits = true }
            // optional minutes group: m<digits>
            if sawDigits, cursor < chars.count, chars[cursor] == "m" {
                cursor += 1
                while cursor < chars.count, chars[cursor].isNumber { cursor += 1 }
            }
            if sawDigits, cursor < chars.count, chars[cursor] == "s" {
                return true
            }
            index += 1
        }
        return false
    }

    /// Glyphs Claude/Codex cycle through for the working spinner.
    private static let spinnerGlyphs: Set<Character> = [
        "✢", "✶", "✻", "✽", "✳", "·", "∗", "⟢", "✦", "✧", "◐", "◓", "◑", "◒",
    ]

    // MARK: - Boundaries

    /// Whether a row marks the top boundary of the current answer: a previous
    /// committed block (tool call / earlier answer) or a user-prompt line. The
    /// streaming answer is the uncommitted text between the boundary and the
    /// status line.
    static func isBoundary(_ row: String, agentKind: ChatAgentKind) -> Bool {
        guard let first = row.trimmingCharacters(in: .whitespaces).first else {
            return false
        }
        return boundaryLeadingGlyphs(for: agentKind).contains(first)
    }

    /// Leading glyphs that begin a committed block or prompt line for an agent.
    static func boundaryLeadingGlyphs(for agentKind: ChatAgentKind) -> Set<Character> {
        switch agentKind {
        case .claude, .other:
            // ⏺ committed block bullet, ● tool bullet, ⎿ tool-result continuation,
            // > user prompt echo, │ prompt-box border.
            return ["⏺", "●", "⎿", ">", "│"]
        case .codex:
            // Codex marks user turns with "user" headers and tool calls with
            // bullets; ">" / box borders are the reliable cross-version anchors.
            return ["•", "›", ">", "│", "⎿"]
        }
    }

    /// Removes a leading committed-block bullet ("⏺ ", "● ", "• ") from a row.
    static func strippingLeadingBullet(_ row: String, agentKind: ChatAgentKind) -> String {
        var working = row
        let leading = Set<Character>(["⏺", "●", "•", "›"])
        if let first = working.first, leading.contains(first) {
            working.removeFirst()
            if working.first == " " { working.removeFirst() }
        }
        return working
    }

    // MARK: - Cleanup

    private static func trimTrailing(_ row: String) -> String {
        var scalars = Array(row.unicodeScalars)
        while let last = scalars.last, last == " " || last == "\t" {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Trims leading/trailing blank rows and collapses runs of 2+ blank rows to
    /// a single blank, so paragraph spacing survives but TUI padding does not.
    static func collapsingBlankRuns(_ rows: [String]) -> [String] {
        var out: [String] = []
        var previousBlank = false
        for row in rows {
            let isBlank = row.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                if previousBlank { continue }
                previousBlank = true
            } else {
                previousBlank = false
            }
            out.append(row)
        }
        while out.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeFirst() }
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out
    }
}
