import CmuxAgentReplica
import Foundation

/// Conservatively extracts an in-flight answer from an agent terminal viewport.
struct AgentGUIProseScreenExtractor: Sendable {
    private static let maxAnswerLines = 200
    private static let spinnerGlyphs: Set<Character> = [
        "✢", "✶", "✻", "✽", "✳", "·", "∗", "⟢", "✦", "✧", "◐", "◓", "◑", "◒",
    ]
    private static let spinnerLeadGlyphs = spinnerGlyphs.subtracting(["·"])

    func extract(lines: [String], agentKind: AgentKind) -> String? {
        let rows = lines.map(Self.trimTrailing)
        guard let anchor = Self.statusLineIndex(in: rows), anchor > 0 else { return nil }
        let answerTops = Self.answerTopBullets(for: agentKind)
        let requiresAnswerTop = !answerTops.isEmpty
        var collected: [String] = []
        var index = anchor - 1
        var foundAnswerTop = false
        while index >= max(0, anchor - Self.maxAnswerLines) {
            let row = rows[index]
            if let first = row.trimmingCharacters(in: .whitespaces).first,
               answerTops.contains(first) {
                collected.append(Self.strippingLeadingBullet(row))
                foundAnswerTop = true
                break
            }
            if Self.isBoundary(row, agentKind: agentKind) { break }
            collected.append(row)
            index -= 1
        }
        guard !requiresAnswerTop || foundAnswerTop else { return nil }
        collected.reverse()
        if let first = collected.first {
            collected[0] = Self.strippingLeadingBullet(first)
        }
        if requiresAnswerTop {
            for index in collected.indices where index > 0 {
                collected[index] = Self.strippingHangingIndent(collected[index])
            }
        }
        let cleaned = Self.collapsingBlankRuns(collected)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func statusLineIndex(in rows: [String]) -> Int? {
        for index in rows.indices.reversed() where isTimerStatusLine(rows[index]) {
            return index
        }
        for index in rows.indices.reversed() where isGerundWorkingLine(rows[index]) {
            return index
        }
        for index in rows.indices.reversed()
        where isInterruptHintLine(rows[index]) && !isModeFooterLine(rows[index]) {
            return index
        }
        return nil
    }

    static func isTimerStatusLine(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let hasSpinner = trimmed.contains { spinnerGlyphs.contains($0) }
        let hasThroughput = lower.contains("token") || trimmed.contains("↓") || trimmed.contains("↑")
        guard hasSpinner || hasThroughput else { return false }
        return hasThroughput ? containsElapsedTimer(trimmed) : containsParenthesizedTimer(trimmed)
    }

    static func containsElapsedTimer(_ text: String) -> Bool {
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index].isNumber else {
                index += 1
                continue
            }
            if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber {
                index += 1
                continue
            }
            var cursor = index
            while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
            if cursor < characters.count, characters[cursor] == "m" {
                let secondsStart = cursor + 1
                if secondsStart < characters.count, characters[secondsStart].isNumber {
                    cursor = secondsStart
                    while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
                }
            }
            if cursor < characters.count, characters[cursor] == "s" {
                let afterSeconds = cursor + 1
                if afterSeconds == characters.count || !characters[afterSeconds].isLetter { return true }
            }
            index = max(index + 1, cursor)
        }
        return false
    }

    static func containsParenthesizedTimer(_ text: String) -> Bool {
        let characters = Array(text)
        for index in characters.indices where characters[index] == "(" {
            var cursor = index + 1
            var sawDigits = false
            while cursor < characters.count, characters[cursor].isNumber {
                cursor += 1
                sawDigits = true
            }
            if sawDigits, cursor < characters.count, characters[cursor] == "m" {
                cursor += 1
                while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
            }
            if sawDigits, cursor < characters.count, characters[cursor] == "s" { return true }
        }
        return false
    }

    private static func isGerundWorkingLine(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, spinnerLeadGlyphs.contains(first) else { return false }
        return trimmed.contains("…")
    }

    private static func isInterruptHintLine(_ row: String) -> Bool {
        let lower = row.lowercased()
        return lower.contains("esc to interrupt") || lower.contains("esc to cancel")
    }

    private static func isModeFooterLine(_ row: String) -> Bool {
        let lower = row.lowercased()
        return lower.contains("shift+tab") || lower.contains("for agents")
            || lower.contains("auto mode") || lower.contains("⏵⏵")
    }

    private static func isBoundary(_ row: String, agentKind: AgentKind) -> Bool {
        guard let first = row.trimmingCharacters(in: .whitespaces).first else { return false }
        switch agentKind {
        case .claude, .unknown:
            return ["●", "⎿", "❯", ">", "│"].contains(first)
        case .codex:
            return ["•", "›", "❯", ">", "│", "⎿"].contains(first)
        }
    }

    private static func answerTopBullets(for agentKind: AgentKind) -> Set<Character> {
        switch agentKind {
        case .claude, .unknown: ["⏺"]
        case .codex: []
        }
    }

    private static func strippingLeadingBullet(_ row: String) -> String {
        var working = row
        if let first = working.first, ["⏺", "●", "•", "›"].contains(first) {
            working.removeFirst()
            if working.first == " " { working.removeFirst() }
        }
        return working
    }

    private static func strippingHangingIndent(_ row: String) -> String {
        var working = Substring(row)
        var removed = 0
        while removed < 2, working.first == " " {
            working = working.dropFirst()
            removed += 1
        }
        return String(working)
    }

    private static func trimTrailing(_ row: String) -> String {
        var scalars = Array(row.unicodeScalars)
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func collapsingBlankRuns(_ rows: [String]) -> [String] {
        var result: [String] = []
        var previousWasBlank = false
        for row in rows {
            let blank = row.trimmingCharacters(in: .whitespaces).isEmpty
            if !blank || !previousWasBlank { result.append(row) }
            previousWasBlank = blank
        }
        while result.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeFirst() }
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeLast() }
        return result
    }
}
