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
    /// The transcript line `uuid` anchoring this checkpoint. `.turn` forks
    /// copy STRICTLY BEFORE this line ("before that prompt ran"); `.manual`
    /// forks copy THROUGH it inclusive.
    let anchorLineUUID: String?
    /// Workspace git HEAD captured at creation (manual checkpoints only).
    let gitSHA: String?
    /// First ~80 chars of the prompt that started the anchored turn.
    let promptSnippet: String?
}

/// Derives turn-boundary checkpoints from a Claude Code session JSONL.
/// Bounded (issue #4535): reads at most `maxBytes` from the start of the file.
enum VaultSessionCheckpoints {
    /// Generous but hard cap on how much transcript one derivation may read.
    nonisolated static let derivationByteCap = 16 * 1024 * 1024
    nonisolated static let snippetLength = 80

    struct Derivation: Equatable, Sendable {
        let checkpoints: [VaultSessionCheckpoint]
        /// True when the byte cap ended the scan early, so later turns exist
        /// that have no checkpoint.
        let isTruncated: Bool
        /// uuid of the last line seen inside the scanned window; anchor for a
        /// manual "checkpoint now".
        let lastLineUUID: String?
    }

    /// Claude-only in this PR: other harnesses don't carry per-line uuids the
    /// fork path can anchor on (cross-harness support is issue #9016's turf).
    nonisolated static func deriveClaudeTurns(
        fileURL: URL,
        maxBytes: Int = derivationByteCap
    ) -> Derivation {
        var checkpoints: [VaultSessionCheckpoint] = []
        var userTurnIndex = 0
        var lastLineUUID: String?
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        _ = SessionIndexJSONLReader().fromStart(url: fileURL, maxBytes: maxBytes) { obj in
            if let uuid = obj["uuid"] as? String, !uuid.isEmpty {
                lastLineUUID = uuid
            }
            guard let prompt = userPromptText(from: obj) else { return false }
            userTurnIndex += 1
            checkpoints.append(
                VaultSessionCheckpoint(
                    id: checkpointID(for: obj, turnIndex: userTurnIndex),
                    source: .turn,
                    timestamp: lineTimestamp(from: obj),
                    name: nil,
                    turnIndex: userTurnIndex,
                    anchorLineUUID: obj["uuid"] as? String,
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
            lastLineUUID: lastLineUUID
        )
    }

    /// Extracts the visible prompt text from a Claude `user` line; nil for
    /// assistant/system/meta lines and tool-result envelopes.
    nonisolated static func userPromptText(from obj: [String: Any]) -> String? {
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

    nonisolated static func snippet(from prompt: String) -> String {
        let singleLine = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > snippetLength else { return singleLine }
        return String(singleLine.prefix(snippetLength)) + "…"
    }

    nonisolated private static func checkpointID(for obj: [String: Any], turnIndex: Int) -> String {
        if let uuid = obj["uuid"] as? String, !uuid.isEmpty {
            return "turn:" + uuid
        }
        return "turn-index:\(turnIndex)"
    }

    nonisolated static func lineTimestamp(from obj: [String: Any]) -> Date? {
        guard let raw = obj["timestamp"] as? String else { return nil }
        if let fractional = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return fractional
        }
        return try? Date(raw, strategy: .iso8601)
    }
}
