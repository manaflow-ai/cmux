import Foundation

extension AcpmuxPaneSocket {
    /// Whether the page waits on a daemon frame, so a pane nobody can see still gets it soon
    /// (``AgentPaneFramePacer``): a reply or a request (an `id`), or `_acpmux/prompt_accepted`,
    /// whose absence fails a sent prompt after a minute (direct.ts `deliveryTiming`). Session
    /// updates, the bulk of a streaming turn, wait until the pane shows. A full flush's backlog
    /// and the close go to a hidden pane too (``pageWaits``), so its queue stays far below the
    /// bound (``AgentPaneTransport/Limits``) and a long hidden stream costs one call per full flush.
    nonisolated static func pageWaits(on object: [String: Any]) -> Bool {
        object["id"] != nil || object["method"] as? String == "_acpmux/prompt_accepted"
    }
}
