import Foundation

/// What the pane's transport does when its page falls a full queue behind the daemon
/// (``AgentPaneTransport/Limits``), as acpmux does for any slow reader (server/outbound.rs):
/// stream notifications are left out, replies and requests are never, and once the page caught up
/// it gets one `_acpmux/lagged` and reads again from its last record (direct.ts `resyncAfterLag`).
///
/// Before, the transport closed the socket instead (`transport.inbound_overflow`). The page then
/// connected again and read its chat and the list anew, which filled the queue again: Leo's chat
/// reconnected every 4 to 9 seconds for minutes at a time (up to 156 closes in 10 minutes on
/// 2026-11-11), redrawing between a kept tail and the live chat each time. One ~31 MB list reply
/// alone took 31 of the queue's 32 MB.
nonisolated enum AcpmuxPaneShedding {
    /// The notice the page gets once a shed episode ends: `watch` because list notices may be
    /// among the shed ones, so the page reads the list again too.
    static func lagMarker(dropped: Int) -> String {
        #"{"jsonrpc":"2.0","method":"_acpmux/lagged","params":{"dropped":\#(dropped),"reason":"host_queue_full","watch":true}}"#
    }

    /// Whether `text` is a notification the page can read again after a lag: a top-level `method`
    /// and no top-level `id` (not a reply, not a request that waits on an answer), and not one a host
    /// observer reads (a permission, a prompt's acceptance), which ``AcpmuxRequestIds`` must see.
    /// Anything it cannot read plainly (an escaped key or method) is kept.
    static func sheddable(_ text: String) -> Bool {
        guard let method = notificationMethod(text) else { return false }
        if method == "_acpmux/event" {
            return !AcpmuxRequestIds.eventObserverMarkers.contains(where: text.contains)
        }
        return !AcpmuxRequestIds.observedNotificationMethods.contains(method)
    }

    /// The top-level `method` of a frame with no top-level `id`; nil for a reply, a request, or a
    /// frame whose keys or method it cannot read without unescaping.
    static func notificationMethod(_ text: String) -> String? {
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
