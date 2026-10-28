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
        guard agentMessageReads[conversation] == nil, pager.isShown(conversation) else { return }
        let epoch = pager.epoch(conversation)
        let turns = (mirror.windows[conversation]?.messages ?? []).map(\.clientMessageID)
        let owner = source
        // task-owner: one run snapshot; cancelled on close or stop, ends when the owner answers
        agentMessageReads[conversation] = Task { [weak self] in
            let runs = await owner.agentRuns(of: conversation, turns: turns)
            guard let self else { return }
            defer {
                if self.pager.epoch(conversation) == epoch { self.agentMessageReads[conversation] = nil }
            }
            guard !Task.isCancelled, !self.stopped, self.pager.isShown(conversation), self.pager.epoch(conversation) == epoch else { return }
            for run in runs { self.applyAgentRun(run) }
        }
    }
}
