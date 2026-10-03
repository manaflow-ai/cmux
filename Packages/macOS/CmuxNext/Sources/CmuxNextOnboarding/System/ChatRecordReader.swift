import Foundation

/// Folds one session file's records into what a chat row shows. See
/// `AgentChatScan` for each app's layout.
nonisolated struct ChatRecordReader {
    let app: AgentApp
    var sessionID: String?
    var cwd: String?
    var summary: String?
    /// Claude prompts, and Codex `user_message` events.
    private var typed = Tally()
    /// Codex user `response_item`s, which repeat each event; used only by
    /// older Codex files that have no events.
    private var items = Tally()

    private struct Tally {
        var count = 0
        var first: String?
        mutating func add(_ text: String) {
            count += 1
            if first == nil { first = ChatRecordReader.titleLine(text) }
        }
    }

    var prompts: Int { typed.count > 0 ? typed.count : items.count }
    var firstPrompt: String? { typed.count > 0 ? typed.first : items.first }

    init(app: AgentApp) {
        self.app = app
    }

    mutating func add(_ record: [String: Any]) {
        switch app {
        case .codex: addCodex(record)
        default: addClaude(record)
        }
    }

    private mutating func addClaude(_ record: [String: Any]) {
        if cwd == nil, let value = record["cwd"] as? String, !value.isEmpty { cwd = value }
        switch record["type"] as? String {
        case "summary":
            if summary == nil { summary = Self.titleLine(record["summary"]) }
        case "user":
            guard record["isMeta"] as? Bool != true,
                  let message = record["message"] as? [String: Any],
                  let text = Self.promptText(message["content"]) else { return }
            typed.add(text)
        default: break
        }
    }

    private mutating func addCodex(_ record: [String: Any]) {
        guard let payload = record["payload"] as? [String: Any] else { return }
        switch (record["type"] as? String, payload["type"] as? String) {
        case ("session_meta", _):
            sessionID = sessionID ?? payload["id"] as? String
            if cwd == nil, let value = payload["cwd"] as? String, !value.isEmpty { cwd = value }
        case ("event_msg", "user_message"):
            if let text = Self.promptText(payload["message"]) { typed.add(text) }
        case ("response_item", "message") where payload["role"] as? String == "user":
            if let text = Self.promptText(payload["content"]) { items.add(text) }
        default: break
        }
    }

    /// The typed text of a prompt: a string, or the text parts of a content
    /// list. Nil for tool results and for context an app injects in `<tags>`.
    static func promptText(_ content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let parts = content as? [[String: Any]] {
            if parts.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = parts.compactMap { part -> String? in
                guard let kind = part["type"] as? String, kind == "text" || kind == "input_text" else { return nil }
                return part["text"] as? String
            }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("<") ? nil : trimmed
    }

    /// The first non-empty line, at most 120 characters.
    static func titleLine(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }
}
