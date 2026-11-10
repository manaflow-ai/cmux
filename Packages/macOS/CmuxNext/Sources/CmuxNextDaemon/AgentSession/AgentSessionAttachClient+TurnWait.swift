import Foundation

/// A chat's turn, pushed: the records of the tab's session after a seq, read over this client's own observation
/// (`agent-session-observe`) until the turn ends, it asks a permission, the attachment closes or the wait passes.
/// What the records mean (the reply, the turn's status) is read by the caller (cmux-tui cloud_start_chat.rs).
extension AgentSessionAttachClient {
    /// What one wait got: acpmux's records (`eventStream` form), the newest seq, and why it ended: `turn_end`,
    /// `permission`, `closed` (with the close's `reason`), `more` (``TurnRecords/kept`` records) or `timeout`.
    public struct TurnRecords: Sendable {
        public static let kept = 2000
        public var records: [JSONValue] = [], lastSeq: UInt64, ended: String?, reason: String?

        init(after: UInt64) { lastSeq = after }

        /// Adds `record` once; true once the wait should end.
        mutating func add(_ record: JSONValue) -> Bool {
            let seq = Self.count(record["seq"]) ?? 0
            guard seq > lastSeq else { return false }
            lastSeq = seq
            records.append(record)
            if record["dir"]?.stringValue == "mux", record["kind"]?.stringValue == "turn_end" { ended = "turn_end" }
            else if records.count >= Self.kept { ended = "more" }
            return ended != nil
        }

        /// A whole non-negative JSON number.
        public static func count(_ value: JSONValue?) -> UInt64? {
            guard let number = value?.doubleValue, number.isFinite, number >= 0 else { return nil }
            return UInt64(min(number, 9_007_199_254_740_992))
        }
    }

    /// Observes the tab (this client must be made with ``Mode/observe``) from `after` until an end or `wait` passes.
    public func turnRecords(after: UInt64?, within wait: Duration) async throws -> TurnRecords {
        let (pushes, push) = AsyncStream.makeStream(of: (String, Data).self)
        let page = try await attach(afterSeq: after, beforeSeq: nil, limit: 500, kinds: nil) { event, line in push.yield((event, line)) }
        var got = TurnRecords(after: after ?? 0)
        if case .array(let events)? = (try? JSONDecoder().decode(JSONValue.self, from: page))?["events"] {
            for record in events where got.add(record) { break }
        }
        if got.ended == nil {
            // task-owner: this wait; it only ends the stream at the deadline, and is cancelled with the wait.
            let timer = Task { try? await Task.sleep(for: wait); push.finish() }
            defer { timer.cancel() }
            pushed: for await (event, line) in pushes {
                guard let object = try? JSONDecoder().decode(JSONValue.self, from: line) else { continue }
                switch event {
                case "agent-session-record":
                    if let record = object["record"], got.add(record) { break pushed }
                case "agent-session-permission":
                    got.ended = "permission"
                    break pushed
                case "agent-session-closed":
                    (got.ended, got.reason) = ("closed", object["reason"]?.stringValue)
                    break pushed
                default: continue
                }
            }
        }
        push.finish()
        return got
    }
}
