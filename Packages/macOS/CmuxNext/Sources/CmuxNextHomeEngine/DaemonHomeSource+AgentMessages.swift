public import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension DaemonHomeSource {
    public func agentRuns(of conversation: ConversationID, window: HomeAgentRunWindow) async -> [HomeAgentRun] {
        guard let connection = try? requireConnection(),
              await connection.identity?.supports(DaemonCapability.conversationRuns.rawValue) == true else { return [] }
        guard let oldest = window.oldestMessageAt else { return [] }
        let all = (try? await ConversationClient(connection).runs(conversation.rawValue,
            oldestStartedAt: oldest.timeIntervalSince1970 * 1000, turns: window.turns.map(\.rawValue),
            answers: window.messageIDs.map(\.rawValue).sorted())) ?? []
        let selected = all.filter { window.contains(turn: $0.turn, answers: $0.answers ?? []) }
        let runs = Dictionary(selected.map { ("\($0.author)\u{0}\($0.id)", $0) }, uniquingKeysWith: { held, next in
            (next.rev ?? next.lastStepSeq ?? 0) > (held.rev ?? held.lastStepSeq ?? 0) ? next : held
        })
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
