import os

extension AgentPaneTransport {
    /// The page lifecycle froze the pane's page and nothing on the connection waits for it (no turn runs,
    /// p13-webui-080): the connection closes, so a frozen chat holds no acpmux socket and acpmux sends it
    /// nothing. Chrome keeps no live WebSocket for a page it puts away either: a page with one stays out
    /// of the back-forward cache (`WebSchedulerTrackedFeature::kWebSocket`,
    /// third_party/blink/public/common/scheduler/web_scheduler_tracked_feature.h).
    ///
    /// The close waits in the frozen pacer behind every frame that arrived before it. At the thaw the page
    /// gets those frames, then the close, and reconnects: acpmux replays the chat on the new connection,
    /// as after an overflow, so the transcript has no gap. A send still in line goes first; the close
    /// follows once the line is empty, unless the page thawed by then (``pageDidThaw()``).
    public func closeWhileFrozen() {
        guard let id = connection, closedForFreeze != id else { return }
        guard pending.isEmpty, !draining else {
            closesWhenSent = true
            return
        }
        closesWhenSent = false
        closedForFreeze = id
        Self.logger.info("agent pane transport closes for the freeze connection=\(id, privacy: .public)")
        close(connection: id)
    }

    /// The page runs again: a freeze's close still waiting for the send line is not made.
    public func pageDidThaw() {
        closesWhenSent = false
    }

    /// The send line emptied: a freeze's close that waited for it goes now.
    func sendLineDidEmpty() {
        if closesWhenSent { closeWhileFrozen() }
    }
}
