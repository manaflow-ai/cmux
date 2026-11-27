import Foundation
import CryptoKit

/// An acpmux permission prompt as the app reads and answers it for the person (cx-aocz, cx-kz6m0.2):
/// the feed bridge (an answer from the phone) and approval banners share this. Allow maps to the
/// offered `allow_once` option, deny to the offered reject option; an option kind offered twice maps
/// to nothing. Shown text is scrubbed of secret shapes and shows invisible characters.
nonisolated enum AcpmuxPermissionPrompt {
    /// One JSON-RPC request line.
    static func frame(id: Int, method: String, params: [String: Any]) -> Data {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        var data = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// sha256 of the request's canonical JSON (sorted keys).
    static func digest(_ request: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The command a tool input runs: a string, or an argv array joined as a shell would read it
    /// (`["bash", "-lc", "rm -rf ~"]` shows as `bash -lc 'rm -rf ~'`). An array with other values
    /// shows as compact JSON.
    static func shownCommand(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let parts = value as? [Any] else { return value.map(compactJSON) }
        guard let words = parts as? [String] else { return compactJSON(parts) }
        return words.map(shellQuoted).joined(separator: " ")
    }

    static func shellQuoted(_ word: String) -> String {
        let plain = !word.isEmpty && word.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_./=:,+@%".unicodeScalars.contains($0)
        }
        return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func compactJSON(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Bidi controls and zero-width characters shown as `<U+XXXX>`, so a command cannot read
    /// one way and run another.
    static func visible(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return AgentPanePolicyFFI.text("prompt_visible", ["text": text]) ?? FeedSecretScrubber.marker
    }

    /// A short, scrubbed summary of a tool's input besides its command: field names with their
    /// values (paths, patterns; other values as compact JSON), `cwd` first whenever present.
    /// `env` is never shown, and its presence marks the summary truncated. `truncated`: a field
    /// beyond the first 8, a long name, a long value, or `env` (the phone then never allows).
    static func inputSummary(_ input: [String: Any]) -> (fields: [String: String], truncated: Bool)? {
        guard let reply = AgentPanePolicyFFI.call("prompt_input_summary", ["input": input]) else {
            // Not read: nothing is shown, and the summary says so (the phone never allows).
            return ([:], true)
        }
        guard let summary = reply["summary"] as? [String: Any] else { return nil }
        return (summary["fields"] as? [String: String] ?? [:], summary["truncated"] as? Bool ?? true)
    }

    static func cut(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return AgentPanePolicyFFI.text("prompt_cut", ["text": text, "limit": max(limit, 1)]) ?? String(text.prefix(max(limit - 1, 0))) + "…"
    }

    /// The one option of kind `allow_once` (allow) or `reject_once` (deny): never a lasting choice.
    static func onceOption(allow: Bool, offered: [[String: Any]]) -> String? {
        AgentPanePolicyFFI.call("prompt_once_option", ["allow": allow, "offered": offered])?["option"] as? String
    }

    /// The one option of kind `allow_always` (a banner's Always allow), else nil.
    static func alwaysOption(offered: [[String: Any]]) -> String? {
        AgentPanePolicyFFI.call("prompt_always_option", ["offered": offered])?["option"] as? String
    }

    static func option(allow: Bool, offered: [[String: Any]]) -> String? {
        AgentPanePolicyFFI.call("prompt_option", ["allow": allow, "offered": offered])?["option"] as? String
    }

    /// The Rust policy's reading of a request (`prompt_read`); nil when it could not run.
    private static func read(_ request: [String: Any]) -> [String: Any]? {
        AgentPanePolicyFFI.call("prompt_read", ["request": request])
    }

    /// The daemon's normalized question of a request, `toolCall._meta.acpmux.question`
    /// (`{harness, agent, items: [{id, header?, prompt, options, …}]}`, acpmux `hub/questions.rs`),
    /// when it is an object.
    static func question(_ request: [String: Any]) -> [String: Any]? {
        read(request)?["question"] as? [String: Any]
    }

    /// True when the request is a question an agent asks a person, never a tool permission: it
    /// carries `toolCall._meta.acpmux.question`, or it is Claude Code's AskUserQuestion
    /// (`_meta.claude.tool`), as acpmux's own `needs_person` reads it.
    static func isQuestion(_ request: [String: Any]) -> Bool {
        read(request)?["is_question"] as? Bool ?? true
    }

    /// A tool permission both buttons can answer: not a question (``isQuestion(_:)``), and it
    /// offers allow once and a deny.
    static func isToolPermission(_ request: [String: Any]) -> Bool {
        read(request)?["is_tool_permission"] as? Bool ?? false
    }

    /// What the prompt asks to do, for a banner: its tool call's title, then the command it runs,
    /// secrets scrubbed and invisible characters shown (as the feed bridge shows them).
    static func summary(_ request: [String: Any]) -> String {
        read(request)?["summary"] as? String ?? ""
    }
}
