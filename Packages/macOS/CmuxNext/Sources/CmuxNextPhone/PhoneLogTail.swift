public import Foundation

/// The error and fault lines of a device log written by `log stream --style
/// ndjson`, newest last, for the feedback summary.
public struct PhoneLogTail: Sendable {
    public struct Line: Sendable, Hashable {
        public var level: String
        public var process: String
        public var message: String
    }

    public let lines: [Line]

    /// Keeps the last `limit` error/fault lines of `ndjson`. Lines that are
    /// not JSON (the stream's header) are skipped.
    public init(ndjson: Data, limit: Int = 8) {
        var kept: [Line] = []
        for raw in ndjson.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  let type = object["messageType"] as? String,
                  type == "Error" || type == "Fault",
                  let message = object["eventMessage"] as? String else { continue }
            let path = object["processImagePath"] as? String ?? ""
            let process = path.split(separator: "/").last.map(String.init) ?? "?"
            kept.append(Line(level: type.lowercased(), process: process,
                             message: message.count > 240 ? String(message.prefix(240)) + "…" : message))
            if kept.count > limit { kept.removeFirst() }
        }
        lines = kept
    }
}
