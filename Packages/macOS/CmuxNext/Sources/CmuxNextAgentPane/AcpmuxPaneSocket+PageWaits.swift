import CmuxNextCompat
import Foundation

extension AcpmuxPaneSocket {
    /// The `_acpmux/event` record kinds the page waits on (the parsed frame's ``pageWaits(on:)``).
    nonisolated static let waitedEventKinds: Set<String> = ["turn_end", "turn_result", "queued", "dequeued", "queue_removed", "prompt_refused"]

    /// The opaque-notification fast path in ``AcpmuxRequestIds`` keeps the original text, and names the frame's
    /// top-level `method` it read (``AcpmuxRequestIds/toPage(_:)``): the method decides, and only an `_acpmux/event`
    /// looks at its text, for its record's `kind`. Before, every frame was scanned in full with Foundation's
    /// `String.contains` for each marker (a `session/update`, the bulk of a stream, three times for markers it never
    /// holds): about two thirds of the inbound queues' CPU on Leo's NIGHTLY, 2026-11-21. A false positive only wakes a
    /// hidden page sooner.
    nonisolated static func pageWaits(on text: String, method: String?) -> Bool {
        switch method {
        case "_acpmux/prompt_accepted", "session/request_permission": true
        case "_acpmux/event": text.utf8HasValue(of: "kind", in: waitedEventKinds)
        case nil: pageWaits(on: text)
        default: false
        }
    }

    /// ``pageWaits(on:method:)`` for a frame whose method was not read: byte searches for the same names.
    nonisolated static func pageWaits(on text: String) -> Bool {
        guard text.utf8Contains("\"method\"") else { return false }
        if text.utf8ContainsAny(["\"_acpmux/prompt_accepted\"", "\"session/request_permission\""]) {
            return true
        }
        guard text.utf8Contains("\"_acpmux/event\"") else { return false }
        return text.utf8HasValue(of: "kind", in: waitedEventKinds)
    }

    /// Whether the page waits on a daemon frame, so a pane nobody can see still gets it soon
    /// (``AgentPaneFramePacer``): a reply or a request (an `id`); `_acpmux/prompt_accepted`, whose
    /// absence fails a sent prompt after a minute (direct.ts `deliveryTiming`); and a turn's end
    /// (`turn_end`, `turn_result`), whose absence 5 s after Stop says the stop was forced
    /// (direct.ts `STOP_GRACE_MS`); and the records that answer a send in place of
    /// `prompt_accepted`: `queued` (a prompt behind a running turn, which acpmux takes with no
    /// acceptance), `dequeued`, `queue_removed` and `prompt_refused`. Without them a held pane left a
    /// prompt sent mid-turn "Still sending" until the turn ended (session claude-7, 2026-10-30).
    /// Session updates, the bulk of a streaming turn, wait until the
    /// pane shows. A full flush's backlog
    /// and the close go to a hidden pane too (``pageWaits``), so its queue stays far below the
    /// bound (``AgentPaneTransport/Limits``) and a long hidden stream costs one call per full flush.
    nonisolated static func pageWaits(on object: [String: Any]) -> Bool {
        if object["id"] != nil { return true }
        switch object["method"] as? String {
        case "_acpmux/prompt_accepted": return true
        case "_acpmux/event":
            return ((object["params"] as? [String: Any])?["kind"] as? String).map(waitedEventKinds.contains) ?? false
        default: return false
        }
    }

    /// Whether a daemon frame answers a request the page sent (a reply: an `id` and no `method`).
    /// Its page is awake (it just asked) and waits on it, so a pane nobody can see gets it without
    /// the hidden interval: a chat opening behind a cover or in a covered window read its attach,
    /// permission groups and handoff about 280 ms late, and each later page of its history 250 ms
    /// late (chat-open bench, 2026-10-31). The page's requests bound these calls; the stream it did
    /// not ask for still waits (``pageWaits(on:)``).
    nonisolated static func answersPage(_ object: [String: Any]) -> Bool {
        object["id"] != nil && object["method"] == nil
    }
}
