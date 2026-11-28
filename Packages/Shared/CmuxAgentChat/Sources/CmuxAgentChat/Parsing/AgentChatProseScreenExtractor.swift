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
        let answerTops = Self.answerTopBullets(for: agentKind)
        // Agents that bullet their live answer (Claude's "⏺ ") require that bullet
        // to be reached, so the early "thinking" screen — where the spinner sits
        // directly under the wrapped user prompt and no answer exists yet — yields
        // nil instead of leaking the prompt's tail as a fake answer.
        let requireAnswerTop = !answerTops.isEmpty
        var collected: [String] = []
        var index = anchor - 1
        var foundAnswerTop = false
        while index >= lowerBound {
            let row = rows[index]
            if let first = row.trimmingCharacters(in: .whitespaces).first,
               answerTops.contains(first) {
                // Inclusive top: the answer's own leading bullet. Include it
                // stripped and stop — anything above belongs to an earlier block.
                collected.append(Self.strippingLeadingBullet(row, agentKind: agentKind))
                foundAnswerTop = true
                break
            }
            if Self.isBoundary(row, agentKind: agentKind) { break }
            collected.append(row)
            index -= 1
        }
        if requireAnswerTop && !foundAnswerTop { return nil }
        collected.reverse()

        // Strip a leading committed-block bullet if the answer just committed
        // on screen (e.g. Claude prefixes a finalized block with "⏺ ").
        if let first = collected.first {
            collected[0] = Self.strippingLeadingBullet(first, agentKind: agentKind)
        }
        // Claude wraps the answer under a 2-space hanging indent aligned past the
        // "⏺ " bullet. Drop it from continuation rows so wrapped lines read as one
        // flowing paragraph rather than an indented block.
        if requireAnswerTop {
            for i in collected.indices where i > 0 {
                collected[i] = Self.strippingHangingIndent(collected[i])
            }
        }

        let cleaned = Self.collapsingBlankRuns(collected)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Removes up to two leading spaces (Claude's hanging-indent width) from a
    /// wrapped answer continuation row; blank rows are returned unchanged.
    static func strippingHangingIndent(_ row: String) -> String {
        var working = Substring(row)
        var removed = 0
        while removed < 2, working.first == " " {
            working = working.dropFirst()
            removed += 1
        }
        return String(working)
    }

    // MARK: - Anchoring

    /// The row to anchor on: the agent's working/status line that sits directly
    /// above the streaming answer.
    ///
    /// Two tiers, because Claude 2.1 renders *two* working signals at once: the
    /// spinner line with the elapsed timer (e.g. `✻ Forming… (4s · ↓ 21 tokens)`)
    /// directly above the answer, and a persistent bottom mode bar that carries
    /// `esc to interrupt` *below* the input box. Anchoring on the lower of the two
    /// (the mode bar) would fold the input box and dividers into the preview, so
    /// the timer line is strongly preferred; the interrupt hint is only a fallback
    /// for layouts/agents that render no timer line (e.g. Codex).
    static func statusLineIndex(in rows: [String]) -> Int? {
        // Tier 1: the spinner line carrying an elapsed timer and throughput,
        // directly above the answer once tokens start (`✻ … (3s · ↓ 1 tokens)`).
        for index in stride(from: rows.count - 1, through: 0, by: -1) {
            if isTimerStatusLine(rows[index]) { return index }
        }
        // Tier 2: the gerund spinner line before the timer appears
        // (`✻ Nebulizing… ` during the first seconds), matched by its leading
        // animated glyph + the trailing ellipsis so the post-turn `Brewed for 3s`
        // summary (no ellipsis) is excluded.
        for index in stride(from: rows.count - 1, through: 0, by: -1) {
            if isGerundWorkingLine(rows[index]) { return index }
        }
        // Tier 3: an explicit interrupt hint *on the working line itself*
        // (Codex's `Working (3s • Esc to interrupt)`). The persistent Claude mode
        // bar also carries that phrase but sits below the input box, so the footer
        // form is excluded — anchoring there would fold in the input box chrome.
        for index in stride(from: rows.count - 1, through: 0, by: -1) {
            if isInterruptHintLine(rows[index]), !isModeFooterLine(rows[index]) { return index }
        }
        return nil
    }

    /// Whether a row is a status line by any signal. Retained for callers/tests
    /// that ask the question without caring which tier matched.
    static func isStatusLine(_ row: String) -> Bool {
        isTimerStatusLine(row) || isGerundWorkingLine(row)
            || (isInterruptHintLine(row) && !isModeFooterLine(row))
    }

    /// Whether a row carries an explicit interrupt hint (`esc to interrupt` /
    /// `esc to cancel`).
    static func isInterruptHintLine(_ row: String) -> Bool {
        let lower = row.lowercased()
        return lower.contains("esc to interrupt") || lower.contains("esc to cancel")
    }

    /// Whether a row is the persistent bottom mode/footer bar rather than a
    /// working line. Identified by its stable footer phrases.
    static func isModeFooterLine(_ row: String) -> Bool {
        let lower = row.lowercased()
        return lower.contains("shift+tab") || lower.contains("for agents")
            || lower.contains("auto mode") || lower.contains("⏵⏵")
    }

    /// Whether a row is Claude's gerund spinner line before the elapsed timer
    /// renders: a leading animated spinner glyph and a trailing `…`. Excludes the
    /// post-turn `Brewed for Ns` summary, which carries no ellipsis.
    static func isGerundWorkingLine(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, Self.spinnerLeadGlyphs.contains(first) else { return false }
        return trimmed.contains("…")
    }

    /// Whether a row is the spinner/elapsed-timer working line that sits directly
    /// above the streaming answer. Matched on stable signals rather than the
    /// (randomized, localized) gerund: an elapsed timer paired with a spinner
    /// glyph or the token/throughput markers Claude shows alongside it, so a
    /// parenthesized `(3s ...)` inside prose is not mistaken for the anchor.
    ///
    /// An *active* turn always pairs the timer with either a parenthesis (`(4s`)
    /// or a throughput marker (`↓ 21 tokens`). The post-turn summary Claude leaves
    /// on screen, `✻ Brewed for 3s`, has a bare timer and neither, so it reads as
    /// settled (no anchor) rather than a still-streaming line.
    static func isTimerStatusLine(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let hasSpinner = trimmed.contains(where: { Self.spinnerGlyphs.contains($0) })
        let hasThroughput = lower.contains("token") || trimmed.contains("↓") || trimmed.contains("↑")
        guard hasSpinner || hasThroughput else { return false }
        if hasThroughput {
            // The "running stop hooks… 0/3 · 3s · ↓ 56 tokens" form drops the
            // paren around the timer, so accept the bare form when throughput
            // markers confirm the turn is live.
            return Self.containsElapsedTimer(trimmed)
        }
        return Self.containsParenthesizedTimer(trimmed)
    }

    /// Whether the row contains an elapsed-time token like `(4s`, `(12s`,
    /// `(1m05s`, or the bare `· 3s ·` form Claude switches to once it starts
    /// running stop hooks (`(running stop hooks… 0/3 · 3s · ↓ 56 tokens)`). The
    /// digit run must start at a word boundary (preceded by a non-alphanumeric)
    /// and the `s` must not be followed by a letter, so neither `0/3` nor a
    /// version like `2.1.191s` is mistaken for a timer. Hand-scanned to avoid a
    /// regex literal, whose `/.../ ` parse is ambiguous next to division.
    static func containsElapsedTimer(_ text: String) -> Bool {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index].isNumber else { index += 1; continue }
            // The digit run must begin at a word boundary so "0/3" or a mid-token
            // digit can't anchor a false match.
            if index > 0 {
                let prev = chars[index - 1]
                if prev.isLetter || prev.isNumber { index += 1; continue }
            }
            var cursor = index
            while cursor < chars.count, chars[cursor].isNumber { cursor += 1 }
            // optional minutes group: m<digits>
            if cursor < chars.count, chars[cursor] == "m" {
                let afterM = cursor + 1
                if afterM < chars.count, chars[afterM].isNumber {
                    cursor = afterM
                    while cursor < chars.count, chars[cursor].isNumber { cursor += 1 }
                }
            }
            if cursor < chars.count, chars[cursor] == "s" {
                let afterS = cursor + 1
                if afterS >= chars.count || !chars[afterS].isLetter {
                    return true
                }
            }
            index = cursor
        }
        return false
    }

    /// Whether the row contains a *parenthesized* elapsed-time token of the form
    /// `(<digits>s` or `(<digits>m<digits>s`, e.g. `(4s`, `(12s`, `(1m05s`. This
    /// is the stricter form used to tell a live working line (`Forming… (9s)`)
    /// from the post-turn `Brewed for 3s` summary, which has a bare timer.
    static func containsParenthesizedTimer(_ text: String) -> Bool {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index] == "(" else { index += 1; continue }
            var cursor = index + 1
            var sawDigits = false
            while cursor < chars.count, chars[cursor].isNumber { cursor += 1; sawDigits = true }
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

    /// Animated spinner glyphs that *lead* the gerund working line. Excludes "·"
    /// (a mid-line separator in the mode bar and prose) so only a genuine spinner
    /// at the start of a row qualifies as the gerund anchor.
    private static let spinnerLeadGlyphs: Set<Character> = [
        "✢", "✶", "✻", "✽", "✳", "∗", "⟢", "✦", "✧", "◐", "◓", "◑", "◒",
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
    /// These are *exclusive* boundaries: collection stops before the row.
    static func boundaryLeadingGlyphs(for agentKind: ChatAgentKind) -> Set<Character> {
        switch agentKind {
        case .claude, .other:
            // ● tool bullet, ⎿ tool-result continuation, ❯/> user prompt echo,
            // │ prompt-box border. (⏺ is handled as an *inclusive* answer top in
            // answerTopBullets, so it is not listed here.)
            return ["●", "⎿", "❯", ">", "│"]
        case .codex:
            // Codex marks user turns with "user" headers and tool calls with
            // bullets; ">" / box borders are the reliable cross-version anchors.
            return ["•", "›", "❯", ">", "│", "⎿"]
        }
    }

    /// Leading glyphs that mark the *inclusive* top of the in-progress answer:
    /// the bullet the agent prefixes onto the streaming block itself. The row is
    /// kept (with the bullet stripped) and collection stops there, so an earlier
    /// committed block above it is excluded. Claude prefixes the live answer with
    /// `⏺ `; Codex prose carries no per-block bullet in v1.
    static func answerTopBullets(for agentKind: ChatAgentKind) -> Set<Character> {
        switch agentKind {
        case .claude, .other:
            return ["⏺"]
        case .codex:
            return []
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
