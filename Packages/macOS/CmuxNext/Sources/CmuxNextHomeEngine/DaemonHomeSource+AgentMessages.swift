import CmuxHomeCore
import CmuxNextDaemon

nonisolated extension DaemonHomeSource {
    public func agentRuns(of conversation: ConversationID, turns: [IdempotencyKey]) async -> [HomeAgentRun] {
        guard let connection = try? requireConnection(),
              await connection.identity?.supports(DaemonCapability.conversationRuns.rawValue) == true else { return [] }
        let all = try? await ConversationClient(connection).runs(conversation.rawValue)
        let replies = turns.isEmpty ? [] : (try? await ConversationClient(connection).runs(
            conversation.rawValue, turns: Array(turns.suffix(200)).map(\.rawValue))) ?? []
        let runs = Dictionary((all ?? []).map { ($0.id, $0) } + replies.map { ($0.id, $0) },
                              uniquingKeysWith: { _, latest in latest })
        var messages: [HomeAgentRun] = []
        for run in runs.values {
            guard !Task.isCancelled else { break }
            if let rows = try? await ConversationClient(connection).runRows(conversation.rawValue, run: run.id) {
                messages.append(HomeAgentRunMapping.run(run, conversation: conversation.rawValue, steps: rows.steps,
                                                        author: { ParticipantID($0) }))
            }
        }
        return messages
    }
}
