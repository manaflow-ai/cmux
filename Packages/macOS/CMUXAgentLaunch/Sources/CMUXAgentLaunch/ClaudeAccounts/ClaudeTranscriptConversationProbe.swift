import Foundation

/// Tells whether a Claude transcript holds a conversation `claude --resume` can continue.
///
/// A conversation record is a JSONL line whose top-level `type` is `user` or `assistant`.
/// Claude Code writes the transcript on a session's first turn; a session that has a name can
/// also get session metadata lines (`ai-title`, `agent-name`) before any turn. A transcript with
/// only those makes `claude --resume <id>` print "No conversation found" and exit.
enum ClaudeTranscriptConversationProbe {
    private static let chunkSize = 64 * 1024
    private static let newline = UInt8(ascii: "\n")

    /// Whether the transcript at `path` has at least one conversation record. Reads in chunks
    /// and stops at the first record, which sits near the top of any real transcript. A line that
    /// is not a JSON object (such as a partial last line still being written) is not a record.
    static func containsConversation(atPath path: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let lineEnd = pending[lineStart...].firstIndex(of: newline) {
                if isConversationRecord(pending[lineStart..<lineEnd]) { return true }
                lineStart = pending.index(after: lineEnd)
            }
            pending = Data(pending[lineStart...])
        }
        return isConversationRecord(pending)
    }

    private static func isConversationRecord(_ line: Data) -> Bool {
        guard !line.isEmpty,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = record["type"] as? String else {
            return false
        }
        return type == "user" || type == "assistant"
    }
}
