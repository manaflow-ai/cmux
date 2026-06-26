import CmuxFoundation
import Foundation

/// Metadata parsed out of a Codex rollout `.jsonl` file by streaming its lines
/// (`session_meta`, `turn_context`, `event_msg`, `response_item`). Fields
/// default to empty/nil so a rollout missing a value simply leaves that field
/// unset.
struct CodexParsed {
    var sessionId: String = ""
    /// First user message — used only if Codex never assigns a thread_name.
    var firstUserMessage: String = ""
    /// Codex-generated session title (`event_msg.thread_name_updated`). Wins over firstUserMessage.
    var threadName: String = ""
    var cwd: String?
    var branch: String?
    var model: String?
    var approvalPolicy: String?
    var sandboxMode: String?
    var effort: String?

    var title: String {
        threadName.isEmpty ? firstUserMessage : threadName
    }

    init() {}

    /// Stream lines from `url` until we have everything we need. The first user_message
    /// can sit ~100 KB into a Codex rollout (after huge base_instructions + AGENTS.md),
    /// so a fixed head buffer is unreliable.
    init(rolloutFileURL url: URL) {
        self.init()
        let maxBytes = 4 * 1024 * 1024
        url.forEachJSONLine(maxBytes: maxBytes) { obj in
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]
            if type == "session_meta", let p = payload {
                if let c = p["cwd"] as? String, !c.isEmpty { self.cwd = c }
                if let id = p["id"] as? String, !id.isEmpty { self.sessionId = id }
                if let git = p["git"] as? [String: Any],
                   let branch = git["branch"] as? String, !branch.isEmpty {
                    self.branch = branch
                }
            }
            if type == "turn_context", let p = payload {
                if let m = p["model"] as? String, !m.isEmpty { self.model = m }
                if let a = p["approval_policy"] as? String, !a.isEmpty { self.approvalPolicy = a }
                if let sandbox = p["sandbox_policy"] as? [String: Any],
                   let s = sandbox["type"] as? String, !s.isEmpty {
                    self.sandboxMode = s
                }
                if let e = p["effort"] as? String, !e.isEmpty { self.effort = e }
            }
            if type == "event_msg", let p = payload,
               (p["type"] as? String) == "thread_name_updated",
               let name = p["thread_name"] as? String, !name.isEmpty {
                self.threadName = name
            }
            if self.firstUserMessage.isEmpty, type == "event_msg", let p = payload,
               (p["type"] as? String) == "user_message",
               let msg = p["message"] as? String,
               let real = Self.realUserMessage(msg) {
                self.firstUserMessage = real
            }
            if self.firstUserMessage.isEmpty, type == "response_item", let p = payload,
               (p["type"] as? String) == "message",
               (p["role"] as? String) == "user",
               let content = p["content"] as? [[String: Any]] {
                for part in content {
                    guard (part["type"] as? String) == "input_text",
                          let text = part["text"] as? String,
                          let real = Self.realUserMessage(text) else { continue }
                    self.firstUserMessage = real
                    break
                }
            }
            // Stop early once we have a real thread name + the launch metadata. If no
            // thread name appears we keep streaming until we at least have a user
            // message — Codex emits thread_name_updated late in newer versions but it's
            // still typically within the first few KB of events.
            return !self.threadName.isEmpty
                && self.cwd != nil
                && self.branch != nil
                && !self.sessionId.isEmpty
                && self.model != nil
        }
    }

    /// Returns a usable user-prompt string from a Codex `user_message` /
    /// `response_item.input_text` payload, or nil when the message is just an
    /// envelope/system wrapper (`<environment_context>...`, `<user_instructions>`,
    /// `<permissions>`, AGENTS.md preamble) that we don't want to surface as a
    /// session title.
    static func realUserMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let envelopePrefixes = [
            "<environment_context",
            "<user_instructions",
            "<permissions",
            "<system",
            "# AGENTS.md",
        ]
        for prefix in envelopePrefixes where trimmed.hasPrefix(prefix) {
            return nil
        }
        return trimmed
    }

    /// Cheap cwd peek for Codex rollouts. `session_meta` is always the first line
    /// of the file, but the line itself can be 30+ KB (it embeds the full system
    /// prompt). Read up to 64 KB to cover that, parse the JSON, return cwd.
    static func peekSessionMetaCwd(url: URL) -> String? {
        let head = url.readFileHead(byteCap: SessionIndexStore.headByteCap)
        guard let nl = head.firstIndex(of: "\n") else { return nil }
        let firstLine = head[..<nl]
        guard let data = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }
        return cwd
    }
}
