import Foundation

/// Clipboard-safe text assembled by the focused chat copy actions. File rows are paths only:
/// config and transcript contents can contain credentials, so each file's contents is its own named
/// palette action (Copy Transcript File, Copy Harness Config File, ...) rather than a side effect of
/// copying session metadata.
enum AgentChatCopyText {
    struct File: Sendable, Hashable {
        let label: String
        let path: String
        let kind: String

        init(label: String, path: String, kind: String = "") {
            self.label = label
            self.path = path
            self.kind = kind
        }
    }

    /// Maps the `files` array of an `_acpmux/session_files` reply to labelled paths, in the
    /// daemon's order. Unknown kinds keep their wire name so a newer daemon's files still show.
    static func files(from reply: [String: Any]?) -> [File] {
        guard let rows = reply?["files"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let kind = row["kind"] as? String, let path = row["path"] as? String, !path.isEmpty else { return nil }
            return File(label: label(kind), path: path, kind: kind)
        }
    }

    static func paths(_ files: [File]) -> String {
        files.filter { !$0.path.isEmpty }.map { "\($0.label): \($0.path)" }.joined(separator: "\n")
    }

    private static func label(_ kind: String) -> String {
        switch kind {
        case "claude_config": "Claude config"
        case "claude_settings": "Claude settings"
        case "codex_config": "Codex config"
        case "transcript": "Transcript"
        case "acpmux_session": "acpmux session"
        case "acpmux_events": "acpmux events"
        default: kind
        }
    }

    static func details(name: String?, identifier: String, harnessSessionID: String?, cwd: String?, host: String?, files: [File]) -> String {
        var lines: [String] = []
        if let name, !name.isEmpty { lines.append("Agent name: \(name)") }
        lines.append("Agent identifier: \(identifier)")
        if let harnessSessionID, !harnessSessionID.isEmpty { lines.append("Harness session ID: \(harnessSessionID)") }
        if let cwd, !cwd.isEmpty { lines.append("CWD: \(cwd)") }
        if let host, !host.isEmpty { lines.append("Host: \(host)") }
        let fileRows = paths(files)
        if !fileRows.isEmpty { lines.append(fileRows) }
        return lines.joined(separator: "\n")
    }
}
