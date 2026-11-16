import AppKit
import CmuxHomeCore
import Foundation

/// A click on an agent's pill opens the agent's own workspace (user 2026-11-07, msg 23836: "we need to get rid
/// of the imessage home split pane completely"). Home never splits: with no link to the agent's session yet
/// (a queued agent) the click shows a small card over the pill with where it stands and, for a queued agent,
/// Start now; the pill's context menu has Start now too, as a registered action's row (user 2026-11-08).
extension HomeNativeTranscriptView {
    /// Opens agent `peer`'s workspace through the host (``onAppLink``) and marks its newest report seen; with no
    /// link, shows its card over `pill` (the pill's frame in this view; nil: near this view's top).
    func openAgent(_ peer: String, at pill: NSRect? = nil) {
        guard !stopped else { return }
        if let onAppLink, let link = agentLink(peer) {
            closeAgentCard()
            onAppLink(link)
            binding.store.markAgentSeen(peer, in: conversationID)
            return
        }
        showAgentCard(peer, at: pill)
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

    /// True while agent `peer` waits in the Chief's queue (not started).
    public func isQueued(_ peer: String) -> Bool {
        binding.store.agentThread(peer, in: conversationID)?.state == .queued
    }

    /// Where agent `peer` stands, one line: its place in the queue, else its state.
    func agentStatus(_ peer: String) -> String {
        let store = binding.store
        switch store.agentThread(peer, in: conversationID)?.state {
        case .queued:
            guard let ahead = store.queuedAgents(in: conversationID).firstIndex(of: peer) else { return HomeAgentPillStrings.queued }
            return ahead == 0 ? HomeAgentPillStrings.startsNext : HomeAgentPillStrings.ahead(ahead)
        case .reported: return HomeAgentPillStrings.reported
        case .stopped: return HomeAgentPillStrings.stopped
        default: return HomeAgentPillStrings.working
        }
    }

    /// The pill's context menu: Start now (the host's registered row, ``startAgentMenuItem``) on a queued agent
    /// the host can start; none otherwise.
    func agentPillMenuItems(_ peer: String) -> [NSMenuItem] {
        guard onStartAgent != nil, isQueued(peer), let item = startAgentMenuItem?(peer) else { return [] }
        item.title = HomeAgentPillStrings.startNow
        item.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
        return [item]
    }

    /// Start now on queued agent `peer` from its card's button: the host asks the Chief to start it past the
    /// cap. A refusal beeps and gives the card its button back; a start closes it.
    func startAgent(_ peer: String) {
        guard let onStartAgent, isQueued(peer) else { return }
        // task-owner: one start request; the view keeps it so tests and a second press see it
        pendingAgentStart = Task { [weak self] in
            let started = await onStartAgent(peer)
            guard let self else { return }
            if started {
                if self.agentCard?.peer == peer { self.closeAgentCard() }
            } else {
                NSSound.beep()
                if self.agentCard?.peer == peer { self.agentCard?.startFailed() }
            }
        }
    }

    private func showAgentCard(_ peer: String, at pill: NSRect?) {
        closeAgentCard()
        let thread = binding.store.agentThread(peer, in: conversationID)
        let card = HomeAgentPillCard(peer: peer, title: thread?.title ?? peer, status: agentStatus(peer),
                                     start: onStartAgent != nil && isQueued(peer) ? { [weak self] in self?.startAgent(peer) } : nil)
        agentCard = card
        guard window?.isVisible == true else { return }
        card.show(beside: pill ?? NSRect(x: bounds.midX - 1, y: bounds.maxY - 80, width: 2, height: 2), of: self)
    }

    /// Closes the card a pill click showed, if any.
    func closeAgentCard() {
        agentCard?.close()
        agentCard = nil
    }
}
