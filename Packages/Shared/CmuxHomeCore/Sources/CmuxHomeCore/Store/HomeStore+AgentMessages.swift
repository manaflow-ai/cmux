import Foundation

extension HomeStore {
    /// Expands the agent-message fold `group` in `conversation`, or collapses it when expanded: a
    /// click on its row (``HomeAgentMessageRow/toggleLink(group:)``). The transcript shows the change.
    public func toggleAgentMessages(_ group: String, in conversation: ConversationID) {
        if expandedAgentMessages[conversation, default: []].remove(group) == nil {
            expandedAgentMessages[conversation, default: []].insert(group)
        }
        bumpTranscript(conversation)
    }

    /// Whether the agent-message fold `group` in `conversation` shows every message.
    public func isAgentMessagesExpanded(_ group: String, in conversation: ConversationID) -> Bool {
        expandedAgentMessages[conversation]?.contains(group) == true
    }

    /// Agent `peer`'s chat with the Chief in `conversation` (the agent pane's content), or nil when no
    /// loaded run has a message with it. Reads the transcript, so an observer follows new reports.
    public func agentThread(_ peer: String, in conversation: ConversationID) -> HomeAgentThread? {
        let items = transcript(for: conversation)
        return agentMessages[conversation]?.thread(peer: peer, in: items, me: me?.id)
    }

    /// The person wrote `text` to agent `peer` from the agent pane: it goes to the Chief's chat as a
    /// ``HomeAgentNote`` (`[to <peer>] <text>`), so the Chief reads it, relays it to the agent and keeps it in
    /// its log, and the agent's chat shows it labelled "You" at once. A send that fails shows Not Delivered
    /// in the chat, as any send.
    ///
    /// - Parameters:
    ///   - text: What the person wrote (trimmed; empty sends nothing).
    ///   - peer: The agent's id.
    ///   - conversation: The Chief's chat.
    /// - Throws: What ``perform(_:key:)`` throws.
    public func sendAgentNote(_ text: String, to peer: String, in conversation: ConversationID) async throws {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        try await perform(.sendMessage(conversation: conversation, parts: [.text(HomeAgentNote(peer: peer, text: words).message)]))
    }

    /// The person opened agent `peer`'s chat: its newest report so far is read, so its pill's unread dot
    /// clears; a newer report shows the dot again. Kept for this launch only.
    public func markAgentSeen(_ peer: String, in conversation: ConversationID) {
        guard let at = agentThread(peer, in: conversation)?.newestReportAt else { return }
        if let seen = agentSeen[conversation]?[peer], seen >= at { return }
        agentSeen[conversation, default: [:]][peer] = at
        bumpTranscript(conversation)
    }

    func applyAgentRun(_ run: HomeAgentRun, preservingLiveAfter snapshot: UInt64? = nil) {
        guard pager.isShown(run.conversation) else { return }
        if agentMessages[run.conversation, default: HomeAgentMessages()].apply(run, preservingLiveAfter: snapshot) {
            bumpTranscript(run.conversation)
        }
    }

    /// A history page is one publication to Home, however many agents it covers.
    /// Merge every run before invalidating the transcript; live events still apply
    /// individually and stale snapshots retain their existing per-step protections.
    func applyAgentRuns(_ runs: [HomeAgentRun], for conversation: ConversationID,
                        preservingLiveAfter snapshot: UInt64? = nil) {
        guard pager.isShown(conversation) else { return }
        var changed = false
        for run in runs where run.conversation == conversation {
            if agentMessages[conversation, default: HomeAgentMessages()].apply(run, preservingLiveAfter: snapshot) {
                changed = true
            }
        }
        if changed { bumpTranscript(conversation) }
    }

    /// One bounded read per shown conversation. Closing or stopping cancels it; reopen gets a new read.
    func requestAgentMessages(_ conversation: ConversationID) {
        guard pager.isShown(conversation), !stopped else { return }
        guard agentMessageReads[conversation] == nil else {
            agentMessageRefreshes.insert(conversation)
            return
        }
        let epoch = pager.epoch(conversation)
        let liveVersion = agentMessages[conversation]?.liveVersion ?? 0
        let window = HomeAgentRunWindow(messages: mirror.windows[conversation]?.messages ?? [])
        let owner = source
        // task-owner: one run snapshot; cancelled on close or stop, ends when the owner answers
        agentMessageReads[conversation] = Task { [weak self] in
            let runs = await owner.agentRuns(of: conversation, window: window)
            guard let self else { return }
            guard self.pager.epoch(conversation) == epoch else { return }
            self.agentMessageReads[conversation] = nil
            guard !Task.isCancelled, !self.stopped, self.pager.isShown(conversation) else { return }
            self.applyAgentRuns(runs, for: conversation, preservingLiveAfter: liveVersion)
            // A history page may arrive while this request is in flight. Follow the newly
            // loaded window once the previous read ends instead of dropping that request.
            let current = HomeAgentRunWindow(messages: self.mirror.windows[conversation]?.messages ?? [])
            let refresh = self.agentMessageRefreshes.remove(conversation) != nil
            if refresh || current != window { self.requestAgentMessages(conversation) }
        }
    }
}
