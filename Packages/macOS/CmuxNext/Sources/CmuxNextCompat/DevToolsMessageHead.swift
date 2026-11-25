import Foundation

/// What a router needs from a raw Chrome DevTools protocol message before anyone parses it: its
/// top-level `method`, read from the first bytes.
///
/// Chromium writes an event as `{"method":"Domain.event","params":{...}}` and a reply as
/// `{"id":N,"result":{...}}`, so the method of nearly every message is known after a few dozen
/// bytes, whatever the message's size. A message in any other shape is parsed in full once, so
/// the answer never depends on key order. Before this, every consumer scanned the whole message
/// with `String.contains` for its own method and name (NIGHTLY 2026-10-29: more than half of the
/// main thread's idle time).
///
/// ```swift
/// let head = DevToolsMessageHead(json: message)
/// guard head.method == "Runtime.bindingCalled", head.contains("\"cmuxMedia\"") else { return }
/// ```
public nonisolated struct DevToolsMessageHead: Sendable {
    /// The message's top-level `method`; nil for a reply, an error, or text that is no JSON object.
    public let method: String?
    /// The whole message, unchanged.
    public let json: String

    /// Reads the top-level method of `json`.
    /// - Parameter json: One raw DevTools message.
    public init(json: String) {
        self.json = json
        method = Self.method(of: json)
    }

    /// Whether the message's UTF-8 bytes contain `needle`'s (a byte search, not a Unicode one:
    /// the needles are protocol names and quoted channels).
    /// - Parameter needle: The text to look for.
    /// - Returns: True when `needle` occurs anywhere in the message.
    public func contains(_ needle: String) -> Bool {
        Self.bytes(json, contain: needle)
    }

    /// ``contains(_:)`` for a message that has no head yet.
    /// - Parameters:
    ///   - json: The text searched.
    ///   - needle: The text to look for.
    /// - Returns: True when `needle`'s UTF-8 bytes occur in `json`'s.
    public static func bytes(_ json: String, contain needle: String) -> Bool {
        var haystack = json
        var pattern = needle
        return haystack.withUTF8 { text in
            pattern.withUTF8 { wanted in
                guard !wanted.isEmpty else { return true }
                guard wanted.count <= text.count, let base = text.baseAddress, let target = wanted.baseAddress else { return false }
                return memmem(base, text.count, target, wanted.count) != nil
            }
        }
    }

    private static let eventPrefix = Array(#"{"method":""#.utf8)
    private static let replyPrefix = Array(#"{"id":"#.utf8)

    private static func method(of json: String) -> String? {
        var text = json
        let head: String?? = text.withUTF8 { bytes in
            if bytes.starts(with: eventPrefix) {
                // Method names are ASCII without escapes: the value ends at the next quote.
                let start = eventPrefix.count
                guard let end = bytes[start...].firstIndex(of: UInt8(ascii: "\"")) else { return .some(nil) }
                let name = bytes[start..<end]
                guard !name.contains(UInt8(ascii: "\\")) else { return nil }
                return .some(String(decoding: name, as: UTF8.self))
            }
            if bytes.starts(with: replyPrefix) { return .some(nil) }
            return nil
        }
        if let head { return head }
        // Another key order or spacing: one full parse finds the top-level key.
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        return object["method"] as? String
    }
}
