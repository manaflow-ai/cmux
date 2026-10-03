import CmuxNextDaemon
import CryptoKit
import Foundation

/// The cloud shape of a handed-off item (`feed.adopt`, backend
/// packages/protocol/src/feed.ts `FeedItem`).
extension FeedHandoffDriver {
    /// The FeedDO id of a local item: stable per install and local id, so
    /// every retry and every later read names the same cloud item. Local ids
    /// (`feeditem_<hex>`) do not match the cloud pattern `fi_[a-z0-9]{20}`.
    nonisolated static func cloudID(install: String, local: String) -> String {
        let digest = SHA256.hash(data: Data("\(install)\n\(local)".utf8))
        return "fi_" + digest.map { String(format: "%02x", $0) }.joined().prefix(20)
    }

    /// `feed.adopt {item}` for a frozen local item: the full cloud item,
    /// homed on this install. A pure function of its inputs, so a retry
    /// sends the same body under the same key. `content` is what the mirror
    /// setting lets leave the Mac; it is scrubbed here again, so nothing
    /// unscrubbed reaches the wire.
    nonisolated static func adoptBody(_ item: FeedLocalItem, install: String,
                                      content: (title: String, body: String)) -> [String: Any] {
        let created = Int(item.createdAtMs)
        let updated = max(created, Int(item.updatedAtMs))
        let high = item.level == "error"
        var context: [String: Any] = [:]
        for (key, value) in [("workspace", item.context.workspace), ("tab", item.context.tab), ("terminal", item.context.terminal)] {
            if let value, !value.isEmpty { context[key] = cut(value, 128) }
        }
        let title = cut(FeedSecretScrubber.scrub(content.title), 200)
        let cloud: [String: Any] = [
            "id": cloudID(install: install, local: item.id),
            "home": "local:\(install)",
            "type": "notice",
            "kind": "notice",
            "title": title.isEmpty ? "cmux" : title,
            "body": cut(FeedSecretScrubber.scrub(content.body), 4096),
            "priority": high ? "high" : "normal",
            "dedupe_key": cut(item.dedupeKey, 200),
            "thread": orNull(item.context.tab.map { cut("tab:\($0)", 200) }),
            "context": context,
            "attachments": [Any](),
            "actions": [Any](),
            "open": NSNull(),
            // A fixed label: never the tab title, which can hold a command line.
            "poster": ["kind": "system", "scope": "inst:\(install)", "label": cut(item.source, 80), "install": install],
            "state": "open",
            "answer": NSNull(),
            "cancel": NSNull(),
            "needs_mac": false,
            "expires_at": created + 7 * 24 * 3_600_000,
            "read_at": orNull(item.readAtMs.map { Int($0) }),
            "seen_at": NSNull(),
            "archived_at": NSNull(),
            "snoozed_until": NSNull(),
            // The owner's default delays (feed.md 7.3); a read item never pushes.
            "push_due_at": orNull(item.readAtMs == nil ? created + (high ? 20_000 : 120_000) : nil),
            "pushed_at": NSNull(),
            "count": Int(item.count),
            "order": 0,
            "revision": 1,
            "created_at": created,
            "updated_at": updated,
            "closed_at": NSNull(),
        ]
        return ["op": "feed.adopt", "params": ["item": cloud], "idempotency_key": "adopt:\(item.id)", "origin": "script"]
    }

    /// Cuts `text` to `max` UTF-16 units (the owner's length unit), on a character boundary.
    nonisolated static func cut(_ text: String, _ max: Int) -> String {
        guard text.utf16.count > max else { return text }
        var out = ""
        var units = 0
        for character in text {
            let width = character.utf16.count
            if units + width > max { break }
            out.append(character)
            units += width
        }
        return out
    }

    nonisolated private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }
}
