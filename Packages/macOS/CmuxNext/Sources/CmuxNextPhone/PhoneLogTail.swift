public import Foundation

/// The error and fault lines of a device log written by `log stream --style
/// ndjson`, newest last, for the feedback summary (`cmux-phone-core`'s op `log_tail`).
public struct PhoneLogTail: Sendable {
    public struct Line: Sendable, Hashable, Decodable {
        public var level: String
        public var process: String
        public var message: String
    }

    public let lines: [Line]

    /// Keeps the last `limit` error/fault lines of `ndjson`. Lines that are
    /// not JSON (the stream's header) are skipped.
    public init(ndjson: Data, limit: Int = 8) {
        lines = (try? PhoneRules.decode([Line].self, "lines", "log_tail",
                                        ["ndjson": PhoneRules.text(ndjson), "limit": max(0, limit)], what: "the device log")) ?? []
    }
}
