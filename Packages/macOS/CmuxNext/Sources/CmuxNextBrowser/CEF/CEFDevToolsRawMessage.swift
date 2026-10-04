import Foundation

/// The DevTools message id rule of the shim (`cmux_cef_shim.h`): raw sends
/// (`cmux_shim_devtools_send`) and shim-internal calls share one id space
/// per browser. Raw sends use ids from 2^30 up to `Int32.max`; the shim
/// assigns its own calls ids below 2^30. A reply with a raw id arrives as
/// `CEFShimEvent.devToolsMessage`, never as `devToolsResult`.
public nonisolated enum CEFDevToolsRawMessage {
    public static let firstRawID = 1 << 30

    public static func isRawID(_ id: Int) -> Bool {
        id >= firstRawID && id <= Int(Int32.max)
    }

    /// The raw-send id a `devToolsMessage` answers, or nil for an event
    /// (no "id") or any other message. A scan of the top-level keys, not a
    /// full parse: protocol output may hold a lone UTF-16 surrogate escape
    /// or deep nesting that a JSON parser refuses (same rule as the shim's
    /// devtools_message_id.h). A repeated "id" gives nil.
    public static func replyID(in json: String) -> Int? {
        guard let id = topLevelID(Array(json.utf8)), isRawID(id) else { return nil }
        return id
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

    private static func skipSpace(_ p: [UInt8], _ i: Int) -> Int {
        var i = i
        while i < p.count, isSpace(p[i]) { i += 1 }
        return i
    }

    /// p[i] is a quote; the index after the closing quote, or nil.
    private static func skipString(_ p: [UInt8], _ i: Int) -> Int? {
        var i = i + 1
        while i < p.count {
            if p[i] == UInt8(ascii: "\\") { i += 2; continue }
            if p[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return nil
    }

    private static func skipValue(_ p: [UInt8], _ i: Int) -> Int? {
        guard i < p.count else { return nil }
        if p[i] == UInt8(ascii: "\"") { return skipString(p, i) }
        if p[i] == UInt8(ascii: "{") || p[i] == UInt8(ascii: "[") {
            var depth = 0
            var i = i
            while i < p.count {
                let c = p[i]
                if c == UInt8(ascii: "\"") {
                    guard let next = skipString(p, i) else { return nil }
                    i = next
                    continue
                }
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                    depth += 1
                } else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return nil
        }
        var j = i
        while j < p.count, p[j] != UInt8(ascii: ","), p[j] != UInt8(ascii: "}"), p[j] != UInt8(ascii: "]"), !isSpace(p[j]) { j += 1 }
        return j == i ? nil : j
    }

    /// The top-level "id" of any message (raw or not), nil as `topLevelID`.
    public static func topLevelID(in json: String) -> Int? { topLevelID(Array(json.utf8)) }

    /// `json` with its top-level "id" replaced by `id` (the browser host
    /// relay maps the host's ids into the raw range and back), nil when the
    /// message has no single integer top-level "id". Every other byte,
    /// "sessionId" included, stays as it was.
    public static func replacingTopLevelID(in json: String, with id: Int) -> String? {
        var bytes = Array(json.utf8)
        guard let (_, span) = scanTopLevelID(bytes) else { return nil }
        bytes.replaceSubrange(span, with: Array(String(id).utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The one integer top-level "id", nil for none, a malformed message,
    /// a non-integer or a repeated "id".
    static func topLevelID(_ p: [UInt8]) -> Int? { scanTopLevelID(p)?.id }

    /// The top-level "id" and the byte range of its number (sign included).
    static func scanTopLevelID(_ p: [UInt8]) -> (id: Int, span: Range<Int>)? {
        var i = skipSpace(p, 0)
        guard i < p.count, p[i] == UInt8(ascii: "{") else { return nil }
        i = skipSpace(p, i + 1)
        var found: (id: Int, span: Range<Int>)?
        if i < p.count, p[i] == UInt8(ascii: "}") { return nil }
        // Every pass consumes at least one byte, so the loop ends within
        // p.count passes; `closed` is set at the object's closing brace.
        var closed = false
        while i < p.count {
            guard p[i] == UInt8(ascii: "\""), let keyEnd = skipString(p, i) else { return nil }
            let isID = keyEnd - i == 4 && p[i + 1] == UInt8(ascii: "i") && p[i + 2] == UInt8(ascii: "d")
            i = skipSpace(p, keyEnd)
            guard i < p.count, p[i] == UInt8(ascii: ":") else { return nil }
            i = skipSpace(p, i + 1)
            if isID {
                guard found == nil else { return nil }
                let start = i
                var negative = false
                if i < p.count, p[i] == UInt8(ascii: "-") { negative = true; i += 1 }
                var digits = 0
                var value = 0
                while i < p.count, p[i] >= UInt8(ascii: "0"), p[i] <= UInt8(ascii: "9") {
                    digits += 1
                    guard digits <= 18 else { return nil }
                    value = value * 10 + Int(p[i] - UInt8(ascii: "0"))
                    i += 1
                }
                guard digits > 0, i >= p.count || p[i] == UInt8(ascii: ",") || p[i] == UInt8(ascii: "}") || isSpace(p[i]) else { return nil }
                found = (negative ? -value : value, start..<i)
            } else {
                guard let next = skipValue(p, i) else { return nil }
                i = next
            }
            i = skipSpace(p, i)
            guard i < p.count else { return nil }
            if p[i] == UInt8(ascii: "}") { closed = true; break }
            guard p[i] == UInt8(ascii: ",") else { return nil }
            i = skipSpace(p, i + 1)
        }
        guard closed else { return nil }
        guard skipSpace(p, i + 1) == p.count else { return nil }
        return found
    }
}
