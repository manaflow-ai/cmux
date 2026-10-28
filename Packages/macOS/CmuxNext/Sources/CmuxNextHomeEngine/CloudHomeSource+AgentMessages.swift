import CmuxHomeCore
import CmuxNextDaemon

nonisolated extension CloudHomeSource {
    public func agentRuns(of conversation: ConversationID, turns: [IdempotencyKey]) async -> [HomeAgentRun] {
        let (commands, identity, agents, generation) = state.withLock { state in
            (state.commands, state.identity,
             state.heads[conversation]?.participants.filter { $0.kind == .agent }.map(\.id) ?? [], state.generation)
        }
        guard let commands, let identity else { return [] }
        var messages: [HomeAgentRun] = []
        for agent in agents {
            guard !Task.isCancelled else { break }
            let runs = (try? await commands.runs(conversation.rawValue, agent: identity.toCloud(agent))) ?? []
            for run in runs {
                guard !Task.isCancelled else { break }
                if let rows = try? await commands.runRows(conversation.rawValue, agent: identity.toCloud(agent), run: run.id) {
                    messages.append(HomeAgentRunMapping.run(run, conversation: conversation.rawValue, steps: rows.steps,
                                                            author: identity.toHome))
                }
            }
        }
        return state.withLock { $0.generation == generation } ? messages : []
    }
}
