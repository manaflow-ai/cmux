import Foundation

/// A deterministic synthetic session for scroll and layout performance measurements.
///
/// Each turn is a user message, an assistant answer of varying length with Markdown
/// (paragraphs, a list, sometimes a code block), and a turn end, so the row mix and
/// heights resemble a real transcript.
public struct AcpmuxSyntheticTranscript: Sendable {
    /// Approximate number of rows to produce.
    public let rowCount: Int

    /// Creates a generator for about `rowCount` rows.
    public init(rowCount: Int) {
        self.rowCount = rowCount
    }

    /// The records, oldest first.
    public func records() -> [AcpmuxEventRecord] {
        var records: [AcpmuxEventRecord] = []
        var seq = 0
        func next(_ dir: String, _ kind: String, _ msg: JSONValue) {
            seq += 1
            records.append(AcpmuxEventRecord(sessionId: "synthetic", seq: seq, at: Int64(seq) * 1_000, dir: dir, kind: kind, msg: msg))
        }
        let turns = max(1, rowCount / 3)
        for turn in 0..<turns {
            next("mux", "user_message", .object(["text": .string("Question \(turn): how should the transcript handle item \(turn % 97)?")]))
            var answer = "Answer \(turn). " + String(repeating: "This sentence adds some width to the paragraph. ", count: 1 + turn % 5)
            if turn % 3 == 0 { answer += "\n\n- first point\n- second point\n- third point" }
            if turn % 7 == 0 { answer += "\n\n```swift\nlet value = \(turn)\nprint(value)\n```" }
            next("in", "agent_message_chunk", .object([
                "jsonrpc": .string("2.0"),
                "method": .string("session/update"),
                "params": .object(["update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(answer)]),
                    "messageId": .string("m\(turn)"),
                ])]),
            ]))
            next("mux", "turn_end", .object(["stopReason": .string("end_turn")]))
        }
        return records
    }
}
