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
}
