import Foundation

/// A pointer into an agent session's transcript: either the start of a user
/// turn (derived, free) or a named manual snapshot of the tip. Checkpoints are
/// pointers, never transcript copies. Distinct from `checkpointId` in
/// `SessionPersistence` (which names a whole resumable session).
struct VaultSessionCheckpoint: Identifiable, Equatable, Sendable, Codable {
    enum Source: String, Codable, Sendable {
        case turn
        case manual
    }

    let id: String
    let source: Source
    /// When the anchored transcript line was written (turn) or the checkpoint
    /// was created (manual).
    let timestamp: Date?
    /// User-supplied name (manual checkpoints only).
    let name: String?
    /// 1-based index of the user turn this checkpoint anchors at (`.turn`),
    /// or the number of user turns seen at creation time (`.manual`).
    let turnIndex: Int
    /// Harness-specific anchor token for the anchored transcript line
    /// (`uuid:<v>` for Claude, `ordinal:<n>`/`line:<n>` for Codex, `id:<v>`
    /// for pi-family, `line:<n>` for Grok). `.turn` forks copy STRICTLY
    /// BEFORE this line ("before that prompt ran"); `.manual` forks copy
    /// THROUGH it inclusive. nil when the harness can't anchor (no fork).
    let anchor: String?
    /// Workspace git HEAD captured at creation (manual checkpoints only).
    let gitSHA: String?
    /// First ~80 chars of the prompt that started the anchored turn.
    let promptSnippet: String?
}

/// Derives turn-boundary checkpoints from session transcripts, per harness.
/// Bounded (issue #4535): raw scans read at most `derivationByteCap` bytes.
enum VaultSessionCheckpoints {
    /// Generous but hard cap on how much transcript one derivation may read.
    nonisolated static let derivationByteCap = 16 * 1024 * 1024
    nonisolated static let snippetLength = 80

    struct Derivation: Equatable, Sendable {
        let checkpoints: [VaultSessionCheckpoint]
        /// True when the byte cap ended the scan early, so later turns exist
        /// that have no checkpoint.
        let isTruncated: Bool
        /// Anchor token of the last line seen inside the scanned window;
        /// anchor for a manual "checkpoint now". nil when the harness has no
        /// stable line anchors.
        let lastAnchor: String?
    }

    /// Streams a JSONL transcript, mapping each line through
    /// harness-specific hooks. Shared by every file-backed harness.
    nonisolated static func deriveFromJSONL(
        fileURL: URL,
        maxBytes: Int = derivationByteCap,
        anchorToken: @escaping ([String: Any], Int) -> String?,
        userPrompt: @escaping ([String: Any]) -> String?
    ) -> Derivation {
        var checkpoints: [VaultSessionCheckpoint] = []
        var userTurnIndex = 0
        var lineIndex = -1
        var lastAnchor: String?
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        _ = SessionIndexJSONLReader().fromStart(url: fileURL, maxBytes: maxBytes) { obj in
            lineIndex += 1
            let anchor = anchorToken(obj, lineIndex)
            if let anchor {
                lastAnchor = anchor
            }
            guard let prompt = userPrompt(obj) else { return false }
            userTurnIndex += 1
            checkpoints.append(
                VaultSessionCheckpoint(
                    id: anchor.map { "turn:" + $0 } ?? "turn-index:\(userTurnIndex)",
                    source: .turn,
                    timestamp: lineTimestamp(from: obj),
                    name: nil,
                    turnIndex: userTurnIndex,
                    anchor: anchor,
                    gitSHA: nil,
                    promptSnippet: snippet(from: prompt)
                )
            )
            return false
        }
        // The reader has no reached-EOF signal; a file exactly at the cap is
        // fully read, so compare against the true size instead of bytesRead.
        return Derivation(
            checkpoints: checkpoints,
            isTruncated: (fileSize ?? 0) > maxBytes,
            lastAnchor: lastAnchor
        )
    }

    // MARK: Claude

    nonisolated static func deriveClaudeTurns(
        fileURL: URL,
        maxBytes: Int = derivationByteCap
    ) -> Derivation {
        deriveFromJSONL(
            fileURL: fileURL,
            maxBytes: maxBytes,
            anchorToken: { obj, _ in
                (obj["uuid"] as? String).flatMap { $0.isEmpty ? nil : "uuid:" + $0 }
            },
            userPrompt: claudeUserPromptText(from:)
        )
    }

    /// Extracts the visible prompt text from a Claude `user` line; nil for
    /// assistant/system/meta lines and tool-result envelopes.
    nonisolated static func claudeUserPromptText(from obj: [String: Any]) -> String? {
        guard (obj["type"] as? String) == "user",
              (obj["isMeta"] as? Bool) != true,
              let message = obj["message"] as? [String: Any],
              (message["role"] as? String) == "user" else {
            return nil
        }
        if let content = message["content"] as? String {
            return SessionEntry.claudeDisplayTitle(from: content, isMeta: false)
        }
        if let parts = message["content"] as? [[String: Any]] {
            for part in parts where (part["type"] as? String) == "text" {
                if let text = part["text"] as? String,
                   let title = SessionEntry.claudeDisplayTitle(from: text, isMeta: false) {
                    return title
                }
            }
        }
        return nil
    }

    // MARK: Codex

    nonisolated static func deriveCodexTurns(
        fileURL: URL,
        maxBytes: Int = derivationByteCap
    ) -> Derivation {
        deriveFromJSONL(
            fileURL: fileURL,
            maxBytes: maxBytes,
            anchorToken: { obj, index in
                if let ordinal = obj["ordinal"] as? Int {
                    return "ordinal:\(ordinal)"
                }
                return "line:\(index)"
            },
            userPrompt: codexUserPromptText(from:)
        )
    }

    /// Real user prompts in a Codex rollout: `event_msg`/`user_message`
    /// events, with `response_item` user messages as the fallback shape.
    /// Envelope payloads (`<environment_context>` etc.) are filtered by
    /// `SessionIndexStore.realCodexUserMessage`.
    nonisolated static func codexUserPromptText(from obj: [String: Any]) -> String? {
        let type = obj["type"] as? String
        guard let payload = obj["payload"] as? [String: Any] else { return nil }
        if type == "event_msg",
           (payload["type"] as? String) == "user_message",
           let message = payload["message"] as? String {
            return SessionIndexStore.realCodexUserMessage(message)
        }
        if type == "response_item",
           (payload["type"] as? String) == "message",
           (payload["role"] as? String) == "user",
           let content = payload["content"] as? [[String: Any]] {
            for part in content where (part["type"] as? String) == "input_text" {
                if let text = part["text"] as? String,
                   let real = SessionIndexStore.realCodexUserMessage(text) {
                    return real
                }
            }
        }
        return nil
    }

    // MARK: Grok

    nonisolated static func deriveGrokTurns(
        fileURL: URL,
        maxBytes: Int = derivationByteCap
    ) -> Derivation {
        deriveFromJSONL(
            fileURL: fileURL,
            maxBytes: maxBytes,
            anchorToken: { _, index in "line:\(index)" },
            userPrompt: grokUserPromptText(from:)
        )
    }

    /// Grok `chat_history.jsonl` user lines: `{"type":"user","content":[...]}`
    /// with tool results and `<user_info>` environment envelopes filtered out.
    nonisolated static func grokUserPromptText(from obj: [String: Any]) -> String? {
        guard (obj["type"] as? String) == "user" else { return nil }
        var text: String?
        if let content = obj["content"] as? String {
            text = content
        } else if let parts = obj["content"] as? [[String: Any]] {
            for part in parts where (part["type"] as? String) == "text" {
                if let value = part["text"] as? String, !value.isEmpty {
                    text = value
                    break
                }
            }
        }
        guard let text, !text.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<user_info"), !trimmed.hasPrefix("<tool_result") else { return nil }
        return trimmed
    }

    // MARK: pi family

    nonisolated static func derivePiFamilyTurns(
        fileURL: URL,
        maxBytes: Int = derivationByteCap
    ) -> Derivation {
        deriveFromJSONL(
            fileURL: fileURL,
            maxBytes: maxBytes,
            anchorToken: { obj, index in
                if let id = obj["id"] as? String, !id.isEmpty {
                    return "id:" + id
                }
                return "line:\(index)"
            },
            userPrompt: piFamilyUserPromptText(from:)
        )
    }

    /// pi-family session lines: `{"type":"message","id":...,"message":
    /// {"role":"user","content":[{"type":"text","text":...}]}}`.
    nonisolated static func piFamilyUserPromptText(from obj: [String: Any]) -> String? {
        guard (obj["type"] as? String) == "message",
              let message = obj["message"] as? [String: Any],
              (message["role"] as? String) == "user" else {
            return nil
        }
        if let content = message["content"] as? String, !content.isEmpty {
            return content
        }
        if let parts = message["content"] as? [[String: Any]] {
            for part in parts where (part["type"] as? String) == "text" {
                if let text = part["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    // MARK: Shared helpers

    nonisolated static func snippet(from prompt: String) -> String {
        let singleLine = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > snippetLength else { return singleLine }
        return String(singleLine.prefix(snippetLength)) + "…"
    }

    nonisolated static func lineTimestamp(from obj: [String: Any]) -> Date? {
        guard let raw = (obj["timestamp"] as? String) ?? (obj["ts"] as? String) else { return nil }
        if let fractional = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return fractional
        }
        return try? Date(raw, strategy: .iso8601)
    }
}
