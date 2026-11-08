import CmuxHomeCore
import Foundation

/// A click on an agent's pill opens the agent's own workspace (user 2026-11-07, msg 23836: "we need to get rid
/// of the imessage home split pane completely"). Home never splits: with no link to the agent's session yet
/// (a queued agent) or no host to open it, the click does nothing here.
extension HomeNativeTranscriptView {
    /// Opens agent `peer`'s workspace through the host (``onAppLink``) and marks its newest report seen.
    func openAgent(_ peer: String) {
        guard !stopped, let onAppLink, let link = agentLink(peer) else { return }
        onAppLink(link)
        binding.store.markAgentSeen(peer, in: conversationID)
    }

    /// Where agent `peer` runs: the Chief's link to its session, or the session's own link once it moved.
    func agentLink(_ peer: String) -> URL? {
        let store = binding.store
        guard let thread = store.agentThread(peer, in: conversationID) else { return nil }
        let session = store.agentSession(peer, in: conversationID)
        // Only this chat's session (a restarted agent has another) counts as moved.
        if let session, session.session == thread.session, session.hasMoved {
            return session.sessionLink ?? thread.workspaceLink
        }
        // A started agent the Chief has not linked yet (one that waited in the queue): its session's own link.
        if thread.workspaceLink == nil, thread.state != .queued, let session, session.peer == thread.peer {
            return session.sessionLink
        }
        return thread.workspaceLink
    }
}
