import Foundation

/// Turns one cmux transcript message into one ACP `session/update`.
///
/// The input is a `ChatMessage` as it appears on the v2 socket
/// (`mobile.chat.history`), read as a dictionary rather than a decoded type:
/// the CLI does not link the chat package, and a mapper that works on the wire
/// shape is also the mapper that catches a field rename in a test.
///
/// Three kinds are dropped on purpose. A permission request and a question are
/// live, answerable things; replaying one as prose would put a dead button in
/// the client's transcript, and forwarding it for real is phase 3. A lifecycle
/// status line has no ACP equivalent. Every drop is counted and reported with
/// the load result, so a client sees that something was left out instead of
/// quietly receiving a shorter conversation than the one on disk.
public struct ACPSessionUpdateMapper {
    /// What one message became.
    public enum Mapping {
        /// The `update` object to put in a `session/update` notification.
        case update([String: Any])
        /// Nothing was sent. The reason is the message kind, or `empty` for a
        /// message whose payload carried no text at all.
        case skipped(reason: String)
    }

    /// The outcome of replaying a page.
    public struct Replay {
        /// `session/update` params, oldest first, ready to be sent.
        public let notifications: [[String: Any]]
        /// How many messages were dropped, by reason.
        public let skipped: [String: Int]

        public init(notifications: [[String: Any]], skipped: [String: Int]) {
            self.notifications = notifications
            self.skipped = skipped
        }
    }

    private let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// Maps a whole history page, oldest first.
    ///
    /// Ordering is the page's, not re-derived here: `mobile.chat.history`
    /// serves ascending `seq`, and a replay that re-sorted would disagree with
    /// the live tail that follows it.
    public func replay(messages: [[String: Any]]) -> Replay {
        var notifications: [[String: Any]] = []
        var skipped: [String: Int] = [:]
        for message in messages {
            switch mapping(for: message) {
            case .update(let update):
                notifications.append(["sessionId": sessionID, "update": update])
            case .skipped(let reason):
                skipped[reason, default: 0] += 1
            }
        }
        return Replay(notifications: notifications, skipped: skipped)
    }

    /// Maps one message.
    public func mapping(for message: [String: Any]) -> Mapping {
        guard let kind = message["kind"] as? [String: Any],
              let type = kind["type"] as? String
        else { return .skipped(reason: "unsupported") }
        let role = (message["role"] as? String) ?? "agent"
        let identifier = (message["id"] as? String) ?? Self.identifier(forSeq: message["seq"])

        switch type {
        case "prose":
            guard let text = Self.text(kind["text"]) else { return .skipped(reason: "empty") }
            // The chunk names are ACP's streaming vocabulary, and a replay is
            // a stream that happens to already be complete: one chunk carries
            // the whole message, which is what a client assembling chunks sees
            // as a finished message.
            let name = role == "user" ? "user_message_chunk" : "agent_message_chunk"
            return .update([
                "sessionUpdate": name,
                "content": Self.textBlock(text),
            ])

        case "thought":
            guard let text = Self.text(kind["text"]) else { return .skipped(reason: "empty") }
            return .update([
                "sessionUpdate": "agent_thought_chunk",
                "content": Self.textBlock(text),
            ])

        case "tool_use":
            return .update(Self.toolCall(kind: kind, identifier: identifier))

        case "terminal":
            return .update(Self.terminalToolCall(kind: kind, identifier: identifier))

        case "file_edit":
            return .update(Self.fileEditToolCall(kind: kind, identifier: identifier))

        case "attachment":
            guard let block = Self.attachmentBlock(kind) else { return .skipped(reason: "empty") }
            return .update([
                "sessionUpdate": role == "user" ? "user_message_chunk" : "agent_message_chunk",
                "content": block,
            ])

        case "permission_request", "question", "status":
            return .skipped(reason: type)

        default:
            return .skipped(reason: "unsupported")
        }
    }

    // MARK: - Tool calls

    private static func toolCall(kind: [String: Any], identifier: String) -> [String: Any] {
        let toolName = (kind["tool_name"] as? String) ?? "tool"
        var update: [String: Any] = [
            "sessionUpdate": "tool_call",
            "toolCallId": identifier,
            "title": Self.text(kind["summary"]) ?? toolName,
            "kind": Self.acpToolKind(forToolNamed: toolName),
            "status": Self.acpToolStatus(kind["status"] as? String),
        ]
        var content: [[String: Any]] = []
        if let output = Self.text(kind["output"]) {
            content.append(["type": "content", "content": Self.textBlock(output)])
        }
        if !content.isEmpty { update["content"] = content }
        if let paths = kind["referenced_paths"] as? [String], !paths.isEmpty {
            update["locations"] = paths.map { ["path": $0] }
        }
        if let detail = Self.text(kind["input_detail"]) {
            // Kept as `rawInput` text rather than parsed: the transcript stores
            // a rendered summary of the call, not the original JSON, and
            // pretending otherwise would hand a client a shape it can't trust.
            update["rawInput"] = ["detail": detail]
        }
        return update
    }

    private static func terminalToolCall(kind: [String: Any], identifier: String) -> [String: Any] {
        let command = Self.text(kind["command"]) ?? "(command)"
        let isRunning = (kind["is_running"] as? Bool) ?? false
        let exitCode = kind["exit_code"] as? Int
        var update: [String: Any] = [
            "sessionUpdate": "tool_call",
            "toolCallId": identifier,
            "title": command,
            "kind": "execute",
            "status": Self.terminalStatus(isRunning: isRunning, exitCode: exitCode),
            "rawInput": ["command": command],
        ]
        if let output = Self.text(kind["output"]) {
            update["content"] = [["type": "content", "content": Self.textBlock(output)]]
        }
        return update
    }

    private static func fileEditToolCall(kind: [String: Any], identifier: String) -> [String: Any] {
        let path = Self.text(kind["file_path"]) ?? "(file)"
        let operation = (kind["operation"] as? String) ?? "edit"
        var update: [String: Any] = [
            "sessionUpdate": "tool_call",
            "toolCallId": identifier,
            "title": "\(operation) \(path)",
            "kind": operation == "delete" ? "delete" : "edit",
            // An edit is in the transcript because it already happened, so
            // there is no state in which replaying it is still pending.
            "status": "completed",
            "locations": [["path": path]],
        ]
        // ACP's diff content block wants the file's before and after text.
        // cmux records a unified diff, so sending it as text is accurate where
        // splitting it into oldText/newText would be a reconstruction.
        if let diff = Self.text(kind["unified_diff"]) {
            update["content"] = [["type": "content", "content": Self.textBlock(diff)]]
        }
        var raw: [String: Any] = ["path": path, "operation": operation]
        if let additions = kind["additions"] as? Int { raw["additions"] = additions }
        if let deletions = kind["deletions"] as? Int { raw["deletions"] = deletions }
        update["rawInput"] = raw
        return update
    }

    // MARK: - Small conversions

    /// ACP's tool-kind hint, from the name the agent used.
    ///
    /// Only exact well-known names map. A near-miss guess is worse than `other`:
    /// a client that trusts `kind` to pick an icon or a confirmation prompt
    /// would show the wrong one, and `other` at least says "unclassified".
    static func acpToolKind(forToolNamed name: String) -> String {
        switch name.lowercased() {
        case "read", "notebookread": return "read"
        case "edit", "multiedit", "write", "notebookedit", "apply_patch": return "edit"
        case "grep", "glob", "search", "codebase_search": return "search"
        case "bash", "shell", "run_command", "bashoutput": return "execute"
        case "webfetch", "web_fetch", "fetch": return "fetch"
        case "websearch", "web_search": return "search"
        case "think", "thinking": return "think"
        default: return "other"
        }
    }

    static func acpToolStatus(_ raw: String?) -> String {
        switch raw {
        case "running": return "in_progress"
        case "succeeded": return "completed"
        case "failed": return "failed"
        // An unrecognized status is reported as in progress, not completed: a
        // client that sees "completed" stops waiting, and claiming a tool run
        // finished when the transcript did not say so is the worse error.
        default: return "in_progress"
        }
    }

    static func terminalStatus(isRunning: Bool, exitCode: Int?) -> String {
        if isRunning { return "in_progress" }
        guard let exitCode else { return "completed" }
        return exitCode == 0 ? "completed" : "failed"
    }

    private static func attachmentBlock(_ kind: [String: Any]) -> [String: Any]? {
        let name = Self.text(kind["display_name"])
        guard let path = Self.text(kind["host_path"]) else {
            // Without a path there is nothing to link to and the bytes are not
            // in the transcript, so a name alone becomes a line of text.
            guard let name else { return nil }
            return Self.textBlock("[attachment: \(name)]")
        }
        var block: [String: Any] = [
            "type": "resource_link",
            "uri": URL(fileURLWithPath: path).absoluteString,
            "name": name ?? (path as NSString).lastPathComponent,
        ]
        if (kind["media"] as? String) == "image" { block["mimeType"] = "image/*" }
        return block
    }

    static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    /// Non-empty text, or nil. Whitespace-only prose is an artifact of terminal
    /// scraping, and forwarding it makes an empty bubble in the client.
    static func text(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    /// Fallback identity for a message whose `id` did not survive the wire.
    ///
    /// Derived from `seq` so it is stable across a re-load of the same
    /// transcript: a tool call the client already saw keeps its id and updates
    /// in place instead of arriving twice.
    static func identifier(forSeq raw: Any?) -> String {
        if let seq = raw as? Int { return "seq-\(seq)" }
        return "seq-unknown-\(UUID().uuidString)"
    }
}
