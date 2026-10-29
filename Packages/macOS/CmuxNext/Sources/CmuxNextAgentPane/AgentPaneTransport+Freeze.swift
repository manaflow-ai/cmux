import os

extension AgentPaneTransport {
    /// The close reason of a connection a freeze let go (webviews bridgeSocket.ts `PAGE_FROZEN_CLOSE_REASON`):
    /// the daemon is still there, so the page opens again on the same client and resumes after the last
    /// event it has, with no "disconnected" frame and no fresh handshake.
    public static let pageFrozenCloseReason = "cmux.page-frozen"

    /// The page lifecycle froze the pane's page and nothing on the connection waits for it (no turn runs):
    /// the connection closes, so a frozen chat holds no acpmux socket and acpmux sends it
    /// nothing. Chrome keeps no live WebSocket for a page it puts away either: a page with one stays out
    /// of the back-forward cache (`WebSchedulerTrackedFeature::kWebSocket`,
    /// third_party/blink/public/common/scheduler/web_scheduler_tracked_feature.h).
    ///
    /// The close waits in the frozen pacer behind every frame that arrived before it. At the thaw the page
    /// gets those frames, then the close (``pageFrozenCloseReason``), and opens again: the new connection
    /// reads the chat from the page's last event, so the transcript has no gap. A send still in line goes
    /// first; the close follows once the line is empty, and only while the page is still frozen.
    public func closeWhileFrozen() {
        guard pacer.pageFrozen else {
            closesWhenSent = false
            return
        }
        guard let id = connection, closedForFreeze != id else { return }
        guard pending.isEmpty, !draining else {
            closesWhenSent = true
            return
        }
        closesWhenSent = false
        closedForFreeze = id
        Self.logger.info("agent pane transport closes for the freeze connection=\(id, privacy: .public)")
        close(connection: id, reason: Self.pageFrozenCloseReason)
    }

    /// The page runs again: a freeze's close still waiting for the send line is not made.
    public func pageDidThaw() {
        closesWhenSent = false
    }

    /// The send line emptied: a freeze's close that waited for it goes now, if the page is still frozen.
    func sendLineDidEmpty() {
        if closesWhenSent { closeWhileFrozen() }
    }
}
