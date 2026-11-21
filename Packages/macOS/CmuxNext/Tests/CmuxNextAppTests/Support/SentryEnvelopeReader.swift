import Foundation

/// Reads a Sentry envelope (a JSON header line, then item header and payload pairs) the way
/// Sentry's ingest does, for end-to-end tests.
nonisolated struct SentryEnvelopeReader {
    /// The first `event` item's JSON, or nil.
    static func event(in envelope: Data) -> [String: Any]? {
        var bytes = [UInt8](envelope)[...]
        guard nextLine(&bytes) != nil else { return nil }
        while let header = nextLine(&bytes) {
            guard let item = try? JSONSerialization.jsonObject(with: Data(header)) as? [String: Any] else { return nil }
            let payload: ArraySlice<UInt8>
            if let length = item["length"] as? Int, bytes.count >= length {
                payload = bytes.prefix(length)
                bytes = bytes.dropFirst(length)
                if bytes.first == 0x0a { bytes = bytes.dropFirst() }
            } else {
                payload = nextLine(&bytes) ?? []
            }
            if item["type"] as? String == "event" {
                return try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any]
            }
        }
        return nil
    }

    /// An event's tags, whether sent as an object or as `[key, value]` pairs.
    static func tags(of event: [String: Any]) -> [String: String] {
        if let object = event["tags"] as? [String: String] { return object }
        let pairs = event["tags"] as? [[String]] ?? []
        return Dictionary(pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }, uniquingKeysWith: { $1 })
    }

    private static func nextLine(_ bytes: inout ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        guard !bytes.isEmpty else { return nil }
        if let newline = bytes.firstIndex(of: 0x0a) {
            let line = bytes[bytes.startIndex..<newline]
            bytes = bytes[(newline + 1)...]
            return line
        }
        let line = bytes
        bytes = []
        return line
    }
}
