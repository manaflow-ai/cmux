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
    /// A subagent transcript's rows shown so far (the opening window, grown a chunk a frame).
    var window: SubagentRowWindow?

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
        // The open builds the rows around where it opens, not all of them (#47189 r3, subagent-2000).
        let window = SubagentRowWindow()
        var source = ChatTranscriptSource(turns: { [unowned store] in store.subagent(id).map { [turn(of: $0)] } ?? [] },
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
                                 window.slice(store.subagent(id).map { memo.rows(for: $0).rows } ?? turn.rows)
                             })
        source.window = window
        return source
    }

    /// A subagent's transcript as a turn: its task is the prompt (none without a task).
    static func turn(of agent: AgentSubagent) -> AgentTurn {
        var turn = agent.asTurn
        if agent.task == nil { turn.prompt = "" }
        return turn
    }
}

/// The rows of a subagent's transcript a list shows so far: at the open, a few screens where it
/// opens (the top of a finished transcript, the end of a running one); then a chunk a frame
/// (`grow`) until every row is in, appended below a finished one's top, or put in above a running
/// one's end (the list keeps the reader's rows in place). A 2000-item transcript's open weighed
/// every row on the main thread (#47189 r3, subagent-2000: 118 ms/s against base's 32.5).
@MainActor
final class SubagentRowWindow {
    /// Rows at the open, and per chunk after it.
    static let first = 60
    static let chunk = 150
    /// The open is at the end (a running transcript) or the top.
    var atEnd = false
    /// Off: every row (a list no host fills, as tests build one). The transcript's host turns it on.
    var enabled = false
    private(set) var lo = 0
    /// nil: to the end.
    private(set) var hi: Int?
    private var opened = false
    private var total = 0

    /// Every row is shown.
    var complete: Bool { !enabled || opened && lo == 0 && hi == nil }

    func slice(_ rows: [TurnRow]) -> [TurnRow] {
        total = rows.count
        guard enabled else { return rows }
        if !opened {
            opened = true
            if atEnd { lo = max(0, rows.count - Self.first) } else if rows.count > Self.first { hi = Self.first }
        }
        let end = min(hi ?? rows.count, rows.count)
        let start = min(lo, end)
        return start == 0 && end == rows.count ? rows : Array(rows[start..<end])
    }

    /// The next chunk; false once every row is shown.
    func grow() -> Bool {
        guard enabled, opened, !complete else { return false }
        if lo > 0 { lo = max(0, lo - Self.chunk) }
        if let hi { self.hi = hi + Self.chunk >= total ? nil : hi + Self.chunk }
        return true
    }
}
#endif
