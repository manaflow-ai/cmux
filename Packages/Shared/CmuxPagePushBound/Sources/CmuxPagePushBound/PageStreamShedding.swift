/// Which daemon frames a page's held stream may drop, as acpmux does for any slow reader
/// (server/outbound.rs), and the notice that ends a drop episode.
///
/// Dropped: notifications (a top-level `method`, no top-level `id`) the page reads again after one
/// `_acpmux/lagged`: transcript records (`_acpmux/event`, `session/update`, both carry the daemon
/// seq that direct.ts `fetchMissedEvents` reads from with `_acpmux/events`), and list, typing,
/// process and peer notices (`watch` in the notice makes the page read the list and its asks again).
///
/// Never dropped:
/// - replies, and requests that wait on an answer (a `session/request_permission` ask has an `id`);
/// - notifications a host observer reads (``keptMethods``: a prompt's acceptance, a pending permission);
/// - transcript records of a prompt the person sent or a permission ask (``keptRecordMarkers``),
///   so the chat shows both without waiting for the gap read;
/// - anything it cannot read plainly (an escaped key or method).
public struct PageStreamShedding: Sendable {
    /// Notifications that are never dropped.
    public static let keptMethods: Set<String> = [
        "_acpmux/prompt_accepted", "_acpmux/permission_pending",
    ]
    /// A transcript record holding one of these JSON strings (a record kind or update kind) is never
    /// dropped: the person's prompt and its refusal, and every permission ask and decision.
    public static let keptRecordMarkers = [
        "\"user_message\"", "\"user_message_chunk\"", "\"prompt_refused\"",
        "\"permission_request\"", "\"permission_reissued\"", "\"permission_decision\"",
    ]
    /// Methods whose frames are transcript records.
    public static let recordMethods: Set<String> = ["_acpmux/event", "session/update"]

    public init() {}

    /// The notice the page gets once a drop episode ends: `watch` because list notices may be
    /// among the dropped ones, so the page reads the list again too.
    public func lagMarker(dropped: Int) -> String {
        #"{"jsonrpc":"2.0","method":"_acpmux/lagged","params":{"dropped":\#(dropped),"reason":"host_queue_full","watch":true}}"#
    }

    /// Whether `text` is a transcript record (it carries a daemon seq the page's cursor follows).
    public func transcriptRecord(_ text: String) -> Bool {
        notificationMethod(text).map(Self.recordMethods.contains) ?? false
    }

    /// Whether `text` may be dropped from a held stream (the type's rules).
    public func sheddable(_ text: String) -> Bool {
        sheddable(text, method: notificationMethod(text))
    }

    /// ``sheddable(_:)`` with the frame's ``notificationMethod(_:)`` already read.
    public func sheddable(_ text: String, method: String?) -> Bool {
        guard let method else { return false }
        if Self.keptMethods.contains(method) { return false }
        if Self.recordMethods.contains(method) {
            return !Self.keptRecordMarkers.contains(where: { text.contains($0) })
        }
        return true
    }

    /// The top-level `method` of a frame with no top-level `id`; nil for a reply, a request, or a
    /// frame whose keys or method it cannot read without unescaping.
    public func notificationMethod(_ text: String) -> String? {
        var text = text
        return text.withUTF8 { bytes -> String? in
            guard let base = bytes.baseAddress else { return nil }
            let count = bytes.count
            var depth = 0
            var i = 0
            var method: String?
            func skipSpace(_ from: Int) -> Int {
                var at = from
                while at < count, base[at] == 0x20 || base[at] == 0x09 || base[at] == 0x0A || base[at] == 0x0D { at += 1 }
                return at
            }
            /// The end quote of the string whose content starts at `from`, and whether it had an escape.
            func stringEnd(_ from: Int) -> (end: Int, escaped: Bool) {
                var at = from
                var escaped = false
                var any = false
                while at < count {
                    let byte = base[at]
                    if escaped { escaped = false }
                    else if byte == 0x5C { escaped = true; any = true }
                    else if byte == 0x22 { break }
                    at += 1
                }
                return (at, any)
            }
            while i < count {
                switch base[i] {
                case 0x22:
                    let start = i + 1
                    let (end, escaped) = stringEnd(start)
                    guard end < count else { return nil }
                    i = end + 1
                    guard depth == 1 else { continue }
                    let colon = skipSpace(i)
                    guard colon < count, base[colon] == 0x3A else { continue }
                    // A key of the top-level object.
                    if escaped { return nil }
                    let length = end - start
                    if length == 2, base[start] == 0x69, base[start + 1] == 0x64 { return nil } // "id"
                    if length == 6, base[start] == 0x6D, base[start + 1] == 0x65, base[start + 2] == 0x74,
                       base[start + 3] == 0x68, base[start + 4] == 0x6F, base[start + 5] == 0x64 { // "method"
                        let value = skipSpace(colon + 1)
                        guard value < count, base[value] == 0x22 else { return nil }
                        let (valueEnd, valueEscaped) = stringEnd(value + 1)
                        guard valueEnd < count, !valueEscaped else { return nil }
                        method = String(decoding: UnsafeBufferPointer(start: base + value + 1, count: valueEnd - value - 1),
                                        as: UTF8.self)
                        i = valueEnd + 1
                    } else {
                        i = colon + 1
                    }
                case 0x7B, 0x5B: depth += 1; i += 1
                case 0x7D, 0x5D: depth -= 1; i += 1
                default: i += 1
                }
            }
            return method
        }
    }
}
