import Foundation

extension AcpmuxPaneSocket {
    /// Whether the page waits on a daemon frame, so a pane nobody can see still gets it soon
    /// (``AgentPaneFramePacer``): a reply or a request (an `id`); `_acpmux/prompt_accepted`, whose
    /// absence fails a sent prompt after a minute (direct.ts `deliveryTiming`); and a turn's end
    /// (`turn_end`, `turn_result`), whose absence 5 s after Stop says the stop was forced
    /// (direct.ts `STOP_GRACE_MS`). Session updates, the bulk of a streaming turn, wait until the
    /// pane shows. A full flush's backlog
    /// and the close go to a hidden pane too (``pageWaits``), so its queue stays far below the
    /// bound (``AgentPaneTransport/Limits``) and a long hidden stream costs one call per full flush.
    nonisolated static func pageWaits(on object: [String: Any]) -> Bool {
        if object["id"] != nil { return true }
        switch object["method"] as? String {
        case "_acpmux/prompt_accepted": return true
        case "_acpmux/event": return ["turn_end", "turn_result"].contains((object["params"] as? [String: Any])?["kind"] as? String)
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
