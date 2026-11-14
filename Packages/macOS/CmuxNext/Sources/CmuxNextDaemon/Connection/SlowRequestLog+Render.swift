import Foundation

// The records of the slow request log and their text. The privacy rule lives here: a line is built
// only from the fields below, and each string in it passes a grammar check first.
extension SlowRequestLog {
    enum Outcome: String, Sendable {
        case ok
        case error
        case timedOut = "timed_out"
        case connectionLost = "connection_lost"
    }

    struct RequestEntry: Sendable {
        var name: String
        /// The request as sent (at most ``maxKeptLineBytes``): only the ids in ``idKeys`` are read from it.
        var line: Data?
        var atMilliseconds: UInt64
        var nanoseconds: UInt64
        var replyBytes: Int?
        var timeoutMilliseconds: Int64?
        var outcome: Outcome
        var error: String?
    }

    struct RollbackEntry: Sendable {
        var name: String
        var atMilliseconds: UInt64
        var nanoseconds: UInt64?
        var error: String?
    }

    enum Entry: Sendable {
        case request(RequestEntry)
        case rollback(RollbackEntry)
    }

    /// How a failed request is recorded; nil for a failure that is not the daemon's or the connection's.
    struct Failure {
        var outcome: Outcome
        var code: String?

        init?(_ error: any Error) {
            guard let error = error as? DaemonError else { return nil }
            switch error {
            case .timedOut, .terminalStartTimedOut: self.init(outcome: .timedOut, code: nil)
            case .command(_, _, let code, _, _): self.init(outcome: .error, code: SlowRequestLog.errorCode(code))
            case .connectionClosed, .daemonShutdown, .notConnected: self.init(outcome: .connectionLost, code: nil)
            default: return nil
            }
        }

        private init(outcome: Outcome, code: String?) {
            self.outcome = outcome
            self.code = code
        }
    }

    /// THE ALLOW-LIST: the only request params a record may hold, in the order of the record. A value
    /// is kept only when it is a whole number or a public id (``isPublicID(_:)``); every other key and
    /// every other value is dropped.
    static let idKeys = ["workspace", "screen", "pane", "tab", "surface", "terminal", "browser"]

    /// What an error with no code, or with a code outside the grammar, is recorded as.
    static let unknownErrorCode = "error"

    /// `code` when it matches `[a-z0-9_.-]{1,48}`, else the word `error`. Never a message.
    static func errorCode(_ code: String?) -> String {
        guard let code, (1...48).contains(code.utf8.count), code.utf8.allSatisfy({ byte in
            (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x5F || byte == 0x2E || byte == 0x2D
        }) else { return unknownErrorCode }
        return code
    }

    /// A command or operation name (`[A-Za-z0-9_.-]{1,64}`), else `unknown`.
    static func safeName(_ name: String) -> String {
        guard (1...64).contains(name.utf8.count), name.utf8.allSatisfy({ byte in
            (0x61...0x7A).contains(byte) || (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte)
                || byte == 0x5F || byte == 0x2E || byte == 0x2D
        }) else { return "unknown" }
        return name
    }

    /// A public id: `<prefix>_<32 hex>`, the prefix 1 to 24 lowercase letters or underscores.
    static func isPublicID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count >= 34, bytes.count <= 57 else { return false }
        let hex = bytes.suffix(32)
        let prefix = bytes.dropLast(33)
        return bytes.dropLast(32).last == 0x5F
            && prefix.allSatisfy { (0x61...0x7A).contains($0) || $0 == 0x5F }
            && hex.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// One allow-listed id of a request: its key and its value as JSON text.
    struct LoggedID {
        var key: String
        var value: String
    }

    /// The allow-listed ids of a request line, in ``idKeys`` order: the top-level fields of a legacy
    /// line, the `params` of a `cmux.protocol/2` request.
    static func ids(in line: Data?) -> [LoggedID] {
        guard let line, let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        let source: [String: Any] = object["protocol"] == nil ? object : (object["params"] as? [String: Any] ?? [:])
        var found: [LoggedID] = []
        for key in idKeys {
            guard let value = source[key] else { continue }
            if let text = value as? String {
                if isPublicID(text) { found.append(LoggedID(key: key, value: "\"\(text)\"")) }
            } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let whole = UInt64(exactly: number) {
                found.append(LoggedID(key: key, value: String(whole)))
            }
        }
        return found
    }

    /// `2026-11-10T15:40:01.123Z` for milliseconds since 1970.
    static func timestamp(milliseconds: UInt64) -> String {
        var seconds = time_t(clamping: milliseconds / 1000)
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", parts.tm_year + 1900, parts.tm_mon + 1,
                      parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec,
                      Int32(truncatingIfNeeded: milliseconds % 1000))
    }

    /// Milliseconds with one decimal.
    static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.1f", Double(nanoseconds) / 1_000_000)
    }

    private static func head(_ kind: String, atMilliseconds: UInt64) -> String {
        "{\"kind\":\"\(kind)\",\"side\":\"app\",\"at\":\"\(timestamp(milliseconds: atMilliseconds))\",\"at_ms\":\(atMilliseconds)"
    }

    /// One record as one JSON object, its keys in the order of the format.
    static func render(_ entry: Entry) -> String {
        switch entry {
        case .request(let request):
            var text = head("request", atMilliseconds: request.atMilliseconds) + ",\"name\":\"\(safeName(request.name))\""
            for id in ids(in: request.line) { text += ",\"\(id.key)\":\(id.value)" }
            text += ",\"total_ms\":\(milliseconds(request.nanoseconds))"
            if let bytes = request.replyBytes { text += ",\"reply_bytes\":\(bytes)" }
            if let timeout = request.timeoutMilliseconds { text += ",\"timeout_ms\":\(timeout)" }
            text += ",\"outcome\":\"\(request.outcome.rawValue)\""
            if let error = request.error { text += ",\"error\":\"\(errorCode(error))\"" }
            return text + "}"
        case .rollback(let rollback):
            var text = head("rollback", atMilliseconds: rollback.atMilliseconds) + ",\"name\":\"\(safeName(rollback.name))\""
            if let nanoseconds = rollback.nanoseconds { text += ",\"total_ms\":\(milliseconds(nanoseconds))" }
            if let error = rollback.error { text += ",\"error\":\"\(errorCode(error))\"" }
            return text + "}"
        }
    }

    /// The record written before the next one when the queue was full for `count` records.
    static func renderDropped(_ count: UInt64, atMilliseconds: UInt64) -> String {
        head("dropped", atMilliseconds: atMilliseconds) + ",\"queue_full\":\(count)}"
    }
}
