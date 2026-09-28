public import Foundation

/// Finds when an agent last replied with visible text, from the tail of its
/// JSONL transcript.
///
/// A reply is an assistant message with non-empty text. Tool calls,
/// reasoning, tool results and subagent (sidechain) messages do not count, so
/// a turn busy with tools keeps the time of the last thing the person could
/// read. Claude's synthetic and API-error assistant lines do not count
/// either. Both transcript shapes are understood:
///
/// - Claude Code: `{"type":"assistant","timestamp":…,"message":{"role":"assistant","content":[{"type":"text",…}]}}`
/// - Codex rollouts: `{"timestamp":…,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text",…}]}}`
public struct AgentTranscriptLastReply: Sendable {
    /// Creates a reader; it holds no state.
    public init() {}

    /// The timestamp of the newest reply in `lines`, or nil when none of them
    /// holds one. Lines are scanned newest first and parsing stops at the
    /// first match, so callers can pass a bounded tail of a large file.
    public func lastReplyDate(inJSONLLines lines: [String]) -> Date? {
        for line in lines.reversed() {
            // Cheap filter before JSON parsing; tool output dominates the tail.
            guard line.contains("\"assistant\""),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let date = replyDate(in: object) else {
                continue
            }
            return date
        }
        return nil
    }

    func replyDate(in object: [String: Any]) -> Date? {
        // Subagent messages and Claude's synthetic or API-error assistant
        // lines are not something the agent said to the person.
        if object["isSidechain"] as? Bool == true || object["isApiErrorMessage"] as? Bool == true {
            return nil
        }
        let message: [String: Any]?
        if let claudeMessage = object["message"] as? [String: Any] {
            message = claudeMessage
        } else if object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message" {
            message = payload
        } else {
            message = nil
        }
        guard let message,
              message["role"] as? String == "assistant",
              message["model"] as? String != "<synthetic>",
              hasVisibleText(message["content"]),
              let rawTimestamp = object["timestamp"] as? String else {
            return nil
        }
        return parseTimestamp(rawTimestamp)
    }

    private func hasVisibleText(_ content: Any?) -> Bool {
        if let text = content as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { block in
            guard let type = block["type"] as? String,
                  type == "text" || type == "output_text",
                  let text = block["text"] as? String else {
                return false
            }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }
}
