import CmuxNextWakeups
public import Foundation
import Synchronization

/// A bounded read of a session journal (`session.journal.subscribe` with
/// `follow:false`, the primitive behind `cmux session current journal
/// read`; cmux-tui/spec/resource-api-v2.md) on a dedicated short-lived
/// connection, so the control connection never carries a long replay.
public struct SessionJournalRead: Sendable {
    public static let shared = Self()
    public struct Result: Sendable {
        /// Each record's JSON (the stream item), in journal order.
        public var records: [Data]
        /// The journal's session id (the cursor generation).
        public var generation: String?
        /// The last delivered sequence; resume after it next time.
        public var lastSequence: UInt64?
        /// True when the stream ended with `completed` (not cut short).
        public var complete: Bool
    }

    /// Reads records of `kinds` after `cursor` (nil: from the beginning),
    /// at most `limit` of them, giving up after `deadline`.
    public func read(socketPath: String, kinds: [String], cursor: (generation: String, sequence: UInt64)?,
                            limit: Int = 20_000, deadline: Duration = .seconds(5)) async throws -> Result {
        let transport = try LineTransport(path: socketPath)
        let streamID = "stream_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let collector = Collector(limit: limit)
        let (ended, endContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        transport.setStreamHandler { id, line in
            guard id == streamID else { return }
            if collector.accept(line) { endContinuation.finish() }
        }
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in endContinuation.finish() })
        defer { transport.close() }
        var params: [String: JSONValue] = [
            "machine": .string("current"), "session": .string("current"), "stream_id": .string(streamID), "follow": .bool(false),
            "filter": .object(["kinds": .array(kinds.map(JSONValue.string)), "max_sensitivity": .string("sensitive")]),
        ]
        if let cursor {
            params["cursor"] = .object(["generation": .string(cursor.generation), "revision": .string(String(cursor.sequence))])
        } else {
            params["start"] = .string("beginning")
        }
        let request = params
        let response = try await transport.request(cmd: "session.journal.subscribe", timeout: deadline) { id in
            let envelope = JSONValue.object([
                "protocol": .string("cmux.protocol/2"), "type": .string("request"), "id": .string(String(id)),
                "operation": .string("session.journal.subscribe"), "params": .object(request),
            ])
            return try JSONEncoder().encode(envelope)
        }
        let opened = try? JSONDecoder().decode(OpenResponse.self, from: response.line)
        let timer = DemandTimer(owner: "SessionJournalRead.shared.deadline")
        timer.schedule(after: deadline) { endContinuation.finish() }
        for await _ in ended {}
        timer.cancel()
        return collector.result(generation: opened?.result?.cursor?.generation)
    }

    private struct OpenResponse: Decodable {
        struct Opened: Decodable { var cursor: Cursor? }
        struct Cursor: Decodable { var generation: String? }
        var result: Opened?
    }

    /// Stream lines, collected on the reader thread.
    private final class Collector: Sendable {
        private struct State {
            var records: [Data] = []
            var generation: String?
            var lastSequence: UInt64?
            var complete = false
            var done = false
        }

        private struct Line: Decodable {
            struct Cursor: Decodable { var generation: String?; var revision: String? }
            var type: String
            var reason: String?
            var cursor: Cursor?
        }

        private let state = Mutex(State())
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        /// Takes one stream line; true once the stream is over.
        func accept(_ line: Data) -> Bool {
            guard let parsed = try? JSONDecoder().decode(Line.self, from: line) else { return false }
            return state.withLock { state in
                guard !state.done else { return true }
                if let generation = parsed.cursor?.generation { state.generation = generation }
                switch parsed.type {
                case "stream_item":
                    if let item = item(of: line) {
                        state.records.append(item)
                        if let revision = parsed.cursor?.revision.flatMap(UInt64.init) { state.lastSequence = revision }
                    }
                    if state.records.count >= limit { state.done = true }
                case "stream_end":
                    state.complete = parsed.reason == "completed"
                    state.done = true
                default:
                    break
                }
                return state.done
            }
        }

        func result(generation: String?) -> Result {
            state.withLock { state in
                Result(records: state.records, generation: state.generation ?? generation, lastSequence: state.lastSequence,
                       complete: state.complete)
            }
        }

        private func item(of line: Data) -> Data? {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let item = object["item"],
                  JSONSerialization.isValidJSONObject(item) else { return nil }
            return try? JSONSerialization.data(withJSONObject: item)
        }
    }
}
