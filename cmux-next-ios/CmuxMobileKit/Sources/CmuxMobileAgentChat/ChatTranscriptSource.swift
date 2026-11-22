#if os(iOS)
import Foundation

/// What a transcript list (`ChatTranscriptList`) shows: an agent chat's turns, or one subagent's
/// transcript as a turn. Read inside the list's observation, so a change to what it reads
/// reloads the list (once per frame: the store applies records per frame).
@MainActor
struct ChatTranscriptSource {
    /// The turns, oldest first.
    var turns: () -> [AgentTurn]
    /// The turn streaming now, or nil.
    var runningTurn: () -> String?
    /// An agent chat's history: older pages load as the reader nears the top, and turns past the
    /// window go to disk. A subagent's transcript holds what the store holds.
    var pagesHistory: Bool
    var mode: ChatTranscriptBuilder.Mode
    /// A subagent transcript's first and last rows (its parent, its state), or nil.
    var frame: () -> (parent: String, footer: SubagentFooter)? = { nil }
    /// The turn's rows kept by what changed (nil: `AgentTurn.rows`).
    var turnRows: ((AgentTurn) -> [TurnRow])?

    /// An agent chat: the store's turns.
    static func chat(_ store: AgentChatStore) -> ChatTranscriptSource {
        ChatTranscriptSource(turns: { [unowned store] in store.turns },
                             runningTurn: { [unowned store] in store.isRunning ? store.turns.last?.id : nil },
                             pagesHistory: true, mode: .chat)
    }

    /// The subagent `id`'s transcript (`AgentSubagent.asTurn`); none once the store no longer
    /// has it.
    static func subagent(_ id: String, store: AgentChatStore) -> ChatTranscriptSource {
        // An append makes the rows it changed, not the transcript's (SUB-6).
        let memo = SubagentRowsMemo()
        return ChatTranscriptSource(turns: { [unowned store] in store.subagent(id).map { [turn(of: $0)] } ?? [] },
                             runningTurn: { [unowned store] in
                                 store.subagent(id).flatMap { $0.state == .running ? turn(of: $0).id : nil }
                             },
                             pagesHistory: false, mode: .subagent,
                             frame: { [unowned store] in
                                 guard let agent = store.subagent(id) else { return nil }
                                 let parent = agent.parent.flatMap { store.subagent($0)?.name } ?? store.summary.name
                                 return (parent, SubagentFooter(agent, offline: store.isOffline))
                             },
                             turnRows: { [unowned store] turn in
                                 store.subagent(id).map { memo.rows(for: $0).rows } ?? turn.rows
                             })
    }

    /// A subagent's transcript as a turn: its task is the prompt (none without a task).
    static func turn(of agent: AgentSubagent) -> AgentTurn {
        var turn = agent.asTurn
        if agent.task == nil { turn.prompt = "" }
        return turn
    }
}
#endif
