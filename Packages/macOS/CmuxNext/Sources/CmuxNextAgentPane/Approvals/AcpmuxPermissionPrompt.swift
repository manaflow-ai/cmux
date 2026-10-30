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
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x061C, 0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
                out += String(format: "<U+%04X>", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// A short, scrubbed summary of a tool's input besides its command: field names with their
    /// values (paths, patterns; other values as compact JSON), `cwd` first whenever present.
    /// `env` is never shown, and its presence marks the summary truncated. `truncated`: a field
    /// beyond the first 8, a long name, a long value, or `env` (the phone then never allows).
    static func inputSummary(_ input: [String: Any]) -> (fields: [String: String], truncated: Bool)? {
        var out: [String: String] = [:]
        let env = input.first { $0.key.lowercased() == "env" }
        var truncated = env.map { !(($0.value as? [String: Any])?.isEmpty ?? false) } ?? false
        let shown = input.filter { $0.key.lowercased() != "env" && $0.key != "command" }
            .sorted { ($0.key == "cwd" ? 0 : 1, $0.key) < ($1.key == "cwd" ? 0 : 1, $1.key) }
        if shown.count > 8 { truncated = true }
        for (key, value) in shown.prefix(8) {
            let raw = value as? String ?? compactJSON(value)
            let scrubbed = FeedSecretScrubber.scrub(raw)
            // A redaction must never hide what the person signs.
            if scrubbed != raw { truncated = true }
            let text = visible(scrubbed)
            if key.count > 40 || text.count > 200 { truncated = true }
            out[cut(visible(key), 40)] = cut(text, 200)
        }
        // Two shown names that read the same after the cut collide: one value is not shown.
        if out.count < min(shown.count, 8) { truncated = true }
        return out.isEmpty && !truncated ? nil : (out, truncated)
    }

    static func cut(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// The one option of kind `allow_once` (allow) or `reject_once` (deny): never a lasting choice.
    static func onceOption(allow: Bool, offered: [[String: Any]]) -> String? {
        let matches = offered.filter { $0["kind"] as? String == (allow ? "allow_once" : "reject_once") }
        return matches.count == 1 ? matches[0]["optionId"] as? String : nil
    }

    static func option(allow: Bool, offered: [[String: Any]]) -> String? {
        let kinds = allow ? ["allow_once"] : ["reject_once", "reject_always"]
        for kind in kinds {
            let matches = offered.filter { $0["kind"] as? String == kind }
            if matches.count == 1, let id = matches[0]["optionId"] as? String { return id }
        }
        return nil
    }

    /// The daemon's normalized question of a request, `toolCall._meta.acpmux.question`
    /// (`{harness, agent, items: [{id, header?, prompt, options, …}]}`, acpmux `hub/questions.rs`),
    /// when it is an object.
    static func question(_ request: [String: Any]) -> [String: Any]? {
        let tool = request["toolCall"] as? [String: Any]
        let acpmux = (tool?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        return acpmux?["question"] as? [String: Any]
    }

    /// True when the request is a question an agent asks a person, never a tool permission: it
    /// carries `toolCall._meta.acpmux.question`, or it is Claude Code's AskUserQuestion
    /// (`_meta.claude.tool`), as acpmux's own `needs_person` reads it.
    static func isQuestion(_ request: [String: Any]) -> Bool {
        let tool = request["toolCall"] as? [String: Any]
        let meta = tool?["_meta"] as? [String: Any]
        return (meta?["acpmux"] as? [String: Any])?["question"] != nil
            || (meta?["claude"] as? [String: Any])?["tool"] as? String == "AskUserQuestion"
    }

    /// A tool permission both buttons can answer: not a question (``isQuestion(_:)``), and it
    /// offers allow once and a deny.
    static func isToolPermission(_ request: [String: Any]) -> Bool {
        let offered = request["options"] as? [[String: Any]] ?? []
        return !isQuestion(request) && option(allow: true, offered: offered) != nil
            && option(allow: false, offered: offered) != nil
    }

    /// What the prompt asks to do, for a banner: its tool call's title, then the command it runs,
    /// secrets scrubbed and invisible characters shown (as the feed bridge shows them).
    static func summary(_ request: [String: Any]) -> String {
        let call = request["toolCall"] as? [String: Any] ?? [:]
        let input = call["rawInput"] as? [String: Any] ?? [:]
        let lines = [call["title"] as? String, shownCommand(input["command"])]
            .compactMap { $0.map { visible(FeedSecretScrubber.scrub($0)) } }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = lines.count == 2 && lines[0] == lines[1] ? [lines[0]] : lines
        return cut(unique.joined(separator: "\n"), 300)
    }
}
