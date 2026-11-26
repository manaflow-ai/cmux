internal import CCmuxLayoutReducerFFI
import Foundation

/// The journal's rules in Rust (`cmux-error-journal`, ops `error_journal_*`) through the app FFI's
/// JSON channel (`cmux_layout_reducer_json`). Swift keeps the I/O (files, the unified log, timers,
/// WebKit); redaction, templates, fingerprints, parsing, the table and every write decision are
/// Rust's. Nil when Rust does not answer.
enum ErrorJournalFFI {
    /// A source op Rust did not answer.
    struct Unanswered: Error, CustomStringConvertible {
        let operation: String
        var description: String { "\(operation) got no answer from the app FFI" }
    }

    static func data(_ operation: String, _ request: [String: Any]) -> Data? {
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = body.withUnsafeBytes { bytes in
                operation.withCString { op in
                    output.withUnsafeMutableBytes { out in
                        cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, body.count, op,
                                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity { capacity = length; continue }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return Data(output.prefix(length))
        }
        return nil
    }

    static func object(_ operation: String, _ request: [String: Any]) -> [String: Any]? {
        data(operation, request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func decode<Reply: Decodable>(_ type: Reply.Type, _ operation: String, _ request: [String: Any]) -> Reply? {
        data(operation, request).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// A source op's `{events, cursor}`.
    static func harvest(_ operation: String, _ request: [String: Any]) throws -> ErrorHarvest {
        guard let reply = decode(HarvestReply.self, operation, request) else { throw Unanswered(operation: operation) }
        return ErrorHarvest(events: reply.events.map(\.event), cursor: reply.cursor)
    }

    static func json(_ event: ErrorEvent) -> [String: Any] {
        var json: [String: Any] = ["source": event.source, "level": event.level.rawValue, "message": event.message,
                                   "context": event.context, "date": event.date.timeIntervalSince1970]
        if let topFrame = event.topFrame { json["top_frame"] = topFrame }
        return json
    }

    static func json(_ entries: [ErrorEntry]) -> Any {
        (try? JSONEncoder().encode(entries)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
    }

    struct HarvestReply: Decodable {
        let events: [WireEvent]
        let cursor: String?
    }

    struct WireEvent: Decodable {
        let source: String
        let level: ErrorLevel
        let message: String
        let topFrame: String?
        let context: [String: String]?
        let date: Double

        enum CodingKeys: String, CodingKey {
            case source, level, message, context, date
            case topFrame = "top_frame"
        }

        var event: ErrorEvent {
            ErrorEvent(source: source, level: level, message: message, topFrame: topFrame, context: context ?? [:],
                       date: Date(timeIntervalSince1970: date))
        }
    }
}

extension ErrorJournalLimits {
    var json: [String: Any] {
        ["segment_bytes": segmentBytes, "max_entries": maxEntries, "max_message_bytes": maxMessageBytes,
         "max_context_value_bytes": maxContextValueBytes, "max_context_keys": maxContextKeys,
         "new_fingerprints_per_minute": newFingerprintsPerMinute, "flush_batch": flushBatch,
         "flush_delay_seconds": flushDelaySeconds]
    }
}

extension ErrorQuery {
    var json: [String: Any] {
        var json: [String: Any] = ["sources": sources, "minimum_level": minimumLevel.rawValue, "order": order.rawValue,
                                   "limit": limit]
        if let since { json["since"] = since.timeIntervalSince1970 }
        if let text { json["text"] = text }
        return json
    }
}
