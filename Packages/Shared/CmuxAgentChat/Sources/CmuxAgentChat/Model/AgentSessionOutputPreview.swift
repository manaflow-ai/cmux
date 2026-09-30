import Foundation

/// Normalizes a short agent output preview for session listings.
public struct AgentSessionOutputPreview: Sendable, Equatable {
    /// Removes terminal control sequences and common Claude Code/Codex chrome.
    public static func cleaned(_ text: String) -> String? {
        let withoutANSI = text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        let lines = withoutANSI
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { line in
                line.hasPrefix("⏺ ") ? String(line.dropFirst(2)) : line
            }
            .filter { !$0.isEmpty }
            .filter { line in
                let scalars = line.unicodeScalars
                guard let first = scalars.first else { return false }
                if "╭╮╰╯│─━┌┐└┘├┤┬┴┼".unicodeScalars.contains(first) { return false }
                if ["❯", "›", ">", "➜", "⏵", "⏳", "✳", "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"].contains(String(first)) { return false }
                let lower = line.lowercased()
                let chrome = [
                    "esc to interrupt", "ctrl+c to interrupt", "ctrl+c to cancel",
                    "shift+tab to switch", "? for shortcuts", "working...",
                    "thinking...", "press enter to send", "bypass permissions"
                ]
                return !chrome.contains { lower.contains($0) }
            }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Returns the newest non-empty cleaned lines, capped for socket payloads.
    public static func tail(_ text: String?, lines: Int) -> String? {
        guard let text, lines > 0, let cleaned = cleaned(text) else { return nil }
        return cleaned.components(separatedBy: .newlines).suffix(lines).joined(separator: "\n")
    }
}
