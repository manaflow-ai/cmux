import Foundation
import os

/// Fallbacks for acpmux daemons and harnesses that do not send a protocol field yet.
///
/// Current acpmux (#15512) sends `promptId` on user records, `message_superseded` for
/// Codex retries, and `errorText`/`errorChunkSeqs` on failed `turn_result`s; the reducer
/// reads those directly. Each method here is the fallback for one missing field, is named
/// for that case, and logs when it runs so a stale daemon is visible in the logs.
struct AcpmuxProtocolAdapter: Sendable {
    private let log = Logger(subsystem: "com.cmuxterm.acpmux", category: "protocol-fallback")

    /// The prompt a `user_message` confirms: its `promptId`, or, for daemons that do not
    /// echo it, the oldest undelivered local echo with the same text.
    func promptID(forUserMessage msg: JSONValue, pendingEchoes: [(promptId: String, text: String)]) -> String? {
        if let promptId = msg["promptId"]?.stringValue { return promptId }
        let text = msg["text"]?.stringValue ?? ""
        let match = pendingEchoes.first { $0.text == text }?.promptId
        if match != nil { log.info("user_message without promptId: matched the local echo by text (old daemon)") }
        return match
    }

    /// For harnesses that do not signal `message_superseded`: whether a new message,
    /// starting with `start`, redelivers the unfinished `abandoned` message before it.
    func fallbackRedeliveryWithoutSupersededSignal(of abandoned: String, restartingWith start: String) -> Bool {
        let head = start.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, abandoned.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(head) else { return false }
        log.info("treated a new messageId as a redelivery by text prefix (no message_superseded signal)")
        return true
    }

    /// For daemons whose failed `turn_result` has no `errorChunkSeqs`: whether streamed
    /// prose is the harness's error text, which belongs in the failure row.
    func fallbackIsStreamedErrorProse(_ text: String, turnError: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, turnError.contains(trimmed) else { return false }
        log.info("hid streamed error prose by text match (turn_result without errorChunkSeqs)")
        return true
    }
}
