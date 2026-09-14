import Foundation

/// One `notification` upsert taken off a cloud machine's `session current events --jsonl`
/// stream (the v2 `session.events` resource stream the headless link already follows).
///
/// Everything here is machine-controlled data. The parser keeps only what the Mac needs:
/// the daemon's public ids (checked against the `<prefix>_<32 lowercase hex>` grammar),
/// and sanitized, capped title/body text. Session ids, timestamps, the unread flag, the
/// level, `extra`, and any UUID-looking field are never read — attribution is decided on
/// the Mac from the link that produced the line plus the terminal id, nothing else.
struct CloudMachineNotificationEvent: Equatable, Sendable {
    static let maxTitleBytes = 128
    static let maxBodyBytes = 1024
    /// A stream line larger than this is ignored before JSON parsing. The daemon caps its
    /// own messages at 4 MiB; a single notification change never needs more than this.
    static let maxLineBytes = 64 * 1024
    /// Notification changes honored per delta; the rest of a flood batch is dropped.
    static let maxNotificationsPerDelta = 16

    /// `notification_<32 hex>` — the daemon's ledger id, used only for de-duplication.
    let id: String
    /// `term_<32 hex>` when the poster passed `--terminal` (the in-VM shim always does
    /// inside a daemon PTY); nil for a session-wide notification.
    let terminalID: String?
    /// Sanitized; may be empty, in which case the host substitutes a title.
    let title: String
    /// Sanitized; may be empty.
    let body: String

    init(id: String, terminalID: String?, title: String, body: String) {
        self.id = id
        self.terminalID = terminalID
        self.title = title
        self.body = body
    }
}

/// What one stream line meant to the notification consumer.
enum CloudMachineStreamItem: Equatable, Sendable {
    /// A `kind:"snapshot"` item. It replays the daemon's durable notification ledger on
    /// every (re)connect, so it never raises notifications.
    case snapshot
    /// A `kind:"delta"` item and the notification upserts it carried (possibly none).
    case delta([CloudMachineNotificationEvent])
    /// Anything else: other envelopes, malformed or oversized lines, non-JSON.
    case ignored
}

extension CloudMachineNotificationEvent {
    static func parse(line: String) -> CloudMachineStreamItem {
        parse(line: Data(line.utf8))
    }

    /// Strict, fail-soft decode of one JSONL line: a malformed change drops that change,
    /// never the stream. Only `{"type":"stream_item","item":{"kind":"delta","changes":[
    /// {"kind":"upsert","resource":"notification","id":…,"value":{…}}]}}` yields events.
    static func parse(line: Data) -> CloudMachineStreamItem {
        guard !line.isEmpty, line.count <= maxLineBytes else { return .ignored }
        // Every line that can matter mentions the resource kind; the tree churn that makes
        // up most of the stream does not, and skips JSON parsing entirely.
        guard line.range(of: Data("notification".utf8)) != nil else { return .ignored }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (object["type"] as? String) == "stream_item",
              let item = object["item"] as? [String: Any],
              let kind = item["kind"] as? String else {
            return .ignored
        }
        switch kind {
        case "snapshot":
            return .snapshot
        case "delta":
            guard let changes = item["changes"] as? [Any] else { return .ignored }
            var events: [CloudMachineNotificationEvent] = []
            for change in changes {
                guard events.count < maxNotificationsPerDelta else { break }
                if let event = event(fromChange: change) {
                    events.append(event)
                }
            }
            return .delta(events)
        default:
            return .ignored
        }
    }

    private static func event(fromChange change: Any) -> CloudMachineNotificationEvent? {
        guard let change = change as? [String: Any],
              (change["kind"] as? String) == "upsert",
              (change["resource"] as? String) == "notification",
              let value = change["value"] as? [String: Any],
              let title = value["title"] as? String else {
            return nil
        }
        let rawID = (value["id"] as? String) ?? (change["id"] as? String)
        guard let id = rawID, isPublicID(id, prefix: "notification") else { return nil }
        let terminalID = (value["terminal_id"] as? String).flatMap { isPublicID($0, prefix: "term") ? $0 : nil }
        let body = (value["body"] as? String) ?? ""
        return CloudMachineNotificationEvent(
            id: id,
            terminalID: terminalID,
            title: NotificationTextSanitizer.sanitize(title, maxBytes: maxTitleBytes),
            body: NotificationTextSanitizer.sanitize(body, maxBytes: maxBodyBytes)
        )
    }

    /// The daemon's public-id grammar: `<prefix>_` + exactly 32 lowercase hex digits.
    static func isPublicID(_ candidate: String, prefix: String) -> Bool {
        let expectedPrefix = prefix + "_"
        guard candidate.utf8.count == expectedPrefix.utf8.count + 32,
              candidate.hasPrefix(expectedPrefix) else {
            return false
        }
        return candidate.utf8.dropFirst(expectedPrefix.utf8.count).allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}
