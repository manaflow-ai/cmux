import Foundation

extension HomeStore {
    func applyAgentRun(_ run: HomeAgentRun) {
        guard pager.isShown(run.conversation) else { return }
        if agentMessages[run.conversation, default: HomeAgentMessages()].apply(run) {
            bumpTranscript(run.conversation)
        }
    }

    /// One bounded read per shown conversation. Closing or stopping cancels it; reopen gets a new read.
    func requestAgentMessages(_ conversation: ConversationID) {
        guard pager.isShown(conversation), !stopped else { return }
        guard agentMessageReads[conversation] == nil else {
            agentMessageRefreshes.insert(conversation)
            return
        }
        let epoch = pager.epoch(conversation)
        let window = HomeAgentRunWindow(messages: mirror.windows[conversation]?.messages ?? [])
        let owner = source
        // task-owner: one run snapshot; cancelled on close or stop, ends when the owner answers
        agentMessageReads[conversation] = Task { [weak self] in
            let runs = await owner.agentRuns(of: conversation, window: window)
            guard let self else { return }
            guard self.pager.epoch(conversation) == epoch else { return }
            self.agentMessageReads[conversation] = nil
            guard !Task.isCancelled, !self.stopped, self.pager.isShown(conversation) else { return }
            for run in runs { self.applyAgentRun(run) }
            // A history page may arrive while this request is in flight. Follow the newly
            // loaded window once the previous read ends instead of dropping that request.
            let current = HomeAgentRunWindow(messages: self.mirror.windows[conversation]?.messages ?? [])
            let refresh = self.agentMessageRefreshes.remove(conversation) != nil
            if refresh || current != window { self.requestAgentMessages(conversation) }
        }
    }
}
