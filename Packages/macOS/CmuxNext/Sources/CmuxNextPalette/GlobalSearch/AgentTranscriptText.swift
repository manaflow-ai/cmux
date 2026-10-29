package import Foundation

/// The conversation text of a Claude Code or Codex session that runs in a
/// terminal on this Mac, read from the agent's transcript file. A TUI agent
/// redraws its screen, so its terminal history holds little of what was
/// said; the transcript holds all of it (the old app searched it too).
package nonisolated struct AgentTranscriptText {
    package nonisolated init() {}
    /// A terminal agent's session, as its hook reported it.
    package nonisolated struct Session: Sendable {
        /// `claude` or `codex` (`TerminalChatRoute.harness(of:)`).
        package let harness: String
        package let sessionID: String
        package let cwd: String?

        package init(harness: String, sessionID: String, cwd: String?) {
            self.harness = harness
            self.sessionID = sessionID
            self.cwd = cwd
        }
    }

    /// The newest bytes of a transcript read: one bounded read however long the session ran.
    package static let readBytes = 4 * 1024 * 1024
    /// Longer lines are tool payloads (images, file dumps), skipped unparsed.
    package static let maxLineBytes = 256 * 1024
    /// Lines kept per session, newest kept.
    package static let maxLines = 20_000
    /// Codex day folders looked through for a session's rollout, newest first.
    package static let codexDays = 120

    /// The session's prompts and replies, one text line per entry, oldest
    /// first; nil when its transcript is not found or not readable.
    /// Off the main actor: it reads and parses up to `readBytes` of a file.
    @concurrent package static func lines(of session: Session, environment: [String: String] = ProcessInfo.processInfo.environment) async -> [String]? {
        guard let url = transcript(of: session, environment: environment), let data = tail(of: url) else { return nil }
        var lines: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) where line.count <= maxLineBytes {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            for text in session.harness == "codex" ? codexTexts(object) : claudeTexts(object) {
                for row in text.split(whereSeparator: \.isNewline) {
                    let trimmed = row.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { lines.append(trimmed) }
                }
            }
        }
        return lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
    }

    /// The transcript file: `$CLAUDE_CONFIG_DIR` or `~/.claude`
    /// `/projects/<cwd slug>/<id>.jsonl` (any project folder when the slug
    /// misses), or `$CODEX_HOME` or `~/.codex` `/sessions/<y>/<m>/<d>/rollout-…-<id>.jsonl`.
    package static func transcript(of session: Session, environment: [String: String]) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let id = session.sessionID
        // A session id names a file: refuse one that could leave its folder.
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
        if session.harness == "codex" {
            let root = (environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex"))
                .appendingPathComponent("sessions")
            let suffix = "-\(id.lowercased()).jsonl"
            var days = 0
            for year in children(of: root) {
                for month in children(of: year) {
                    for day in children(of: month) {
                        if let name = (try? fm.contentsOfDirectory(atPath: day.path))?.first(where: { $0.lowercased().hasSuffix(suffix) }) {
                            return day.appendingPathComponent(name)
                        }
                        days += 1
                        if days >= codexDays { return nil }
                    }
                }
            }
            return nil
        }
        let projects = (environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude"))
            .appendingPathComponent("projects")
        let file = "\(id).jsonl"
        if let cwd = session.cwd {
            let slug = String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
            let candidate = projects.appendingPathComponent(slug).appendingPathComponent(file)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        for project in children(of: projects) {
            let candidate = project.appendingPathComponent(file)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Subfolders, newest name first (Codex folders are dates).
    private static func children(of url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >).map { url.appendingPathComponent($0) }
    }

    /// The last `readBytes` of the file, from its first whole line.
    private static func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(readBytes) ? size - UInt64(readBytes) : 0
        try? handle.seek(toOffset: start)
        // concurrency-allow: called only from the @concurrent lines(of:), never on the main thread.
        guard var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.index(after: newline)...]
        }
        return data
    }

    /// Entries the harness writes itself, not what was said (a prompt of pasted HTML still counts).
    package static let claudeWrappers = ["<command-", "<local-command-", "<system-reminder>", "<user-prompt-submit-hook>", "<bash-",
                                 "<task-notification>", "<command-message>"]
    package static let codexWrappers = ["<environment_context>", "<user_instructions>", "<permissions", "<turn_aborted>", "# AGENTS.md"]

    /// A Claude Code line's user or assistant text. Wrapped entries (`<command-name>`,
    /// `<system-reminder>`, …) are the harness's own and are skipped.
    package static func claudeTexts(_ object: [String: Any]) -> [String] {
        guard let type = object["type"] as? String, type == "user" || type == "assistant",
              object["isMeta"] as? Bool != true, let message = object["message"] as? [String: Any] else { return [] }
        let texts: [String]
        if let text = message["content"] as? String {
            texts = [text]
        } else if let blocks = message["content"] as? [[String: Any]] {
            texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        } else {
            texts = []
        }
        return texts.filter { text in !claudeWrappers.contains { text.hasPrefix($0) } }
    }

    /// A Codex rollout line's user or assistant message text; the injected
    /// context entries (`<environment_context>`, AGENTS.md) are skipped.
    package static func codexTexts(_ object: [String: Any]) -> [String] {
        guard object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "message", let role = payload["role"] as? String, role == "user" || role == "assistant",
              let blocks = payload["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String, type == "input_text" || type == "output_text",
                  let text = block["text"] as? String, !codexWrappers.contains(where: { text.hasPrefix($0) }) else { return nil }
            return text
        }
    }
}
