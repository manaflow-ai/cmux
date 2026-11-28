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
        var source = ChatTranscriptSource(turns: { [unowned store] in
                                 guard let agent = store.subagent(id) else { return [] }
                                 let rows = memo.rows(for: agent).rows
                                 return window.turns(base: turn(of: agent), rows: rows, starts: memo.starts,
                                                     unchanged: memo.unchangedPrefix)
                             },
                             runningTurn: { [unowned store] in
                                 store.subagent(id).flatMap { $0.state == .running ? window.lastTurnID ?? turn(of: $0).id : nil }
                             },
                             pagesHistory: false, mode: .subagent,
                             frame: { [unowned store] in
                                 guard let agent = store.subagent(id) else { return nil }
                                 let parent = agent.parent.flatMap { store.subagent($0)?.name } ?? store.summary.name
                                 return (parent, SubagentFooter(agent, offline: store.isOffline))
                             },
                             turnRows: { [unowned store] turn in
                                 window.rows(of: turn.id) ?? store.subagent(id).map { memo.rows(for: $0).rows } ?? turn.rows
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

/// The rows of a subagent's transcript a list shows so far, as turns of a chunk each: at the open,
/// a few screens where it opens (the top of a finished transcript, the end of a running one); then
/// a chunk a frame (`grow`) until every row is in, below a finished one's top or above a running
/// one's end. Each chunk is its own turn to the list, so a growth builds and weighs the new chunk
/// only (one turn made the list rebuild every row on each growth: 140 ms a chunk, #47189 r4).
/// A 2000-item transcript's open weighed every row on the main thread (#47189 r3, subagent-2000).
@MainActor
final class SubagentRowWindow {
    /// Rows at the open, and per chunk after it.
    static let first = 60
    static var chunk = 150
    /// The open is at the end (a running transcript) or the top.
    var atEnd = false
    /// Off: every row, as one turn (a list no host fills, as tests and the golden rows build one).
    var enabled = false

    /// A chunk: its key (stable: 0 at the open, 1, 2 below it or -1, -2 above it) and first row.
    private struct Chunk {
        var key: Int
        var start: Int
    }
    private var chunks: [Chunk] = []
    /// One past the last row shown (nil: to the transcript's end).
    private var hi: Int?
    private var opened = false
    private var total = 0
    /// Each chunk's turn as last made, and the rows it was made for.
    private var made: [Int: (turn: AgentTurn, range: Range<Int>)] = [:]
    /// The rows of each chunk's turn, by turn id (the builder's `turnRows`).
    private var rowsByTurn: [String: ArraySlice<TurnRow>] = [:]
    /// The chunk turns, by id: whether each continues the one above it.
    private var continuing: Set<String> = []
    private(set) var lastTurnID: String?

    /// Every row is shown.
    var complete: Bool { !enabled || opened && (chunks.first?.start ?? 0) == 0 && hi == nil }

    /// The transcript `base` (its rows `rows`, each starting at item `starts[i]`, the first
    /// `unchanged` as they were at the last call) as the turns of the chunks shown.
    func turns(base: AgentTurn, rows: [TurnRow], starts: [Int], unchanged: Int) -> [AgentTurn] {
        total = rows.count
        guard enabled else {
            rowsByTurn = [:]
            continuing = []
            lastTurnID = base.id
            return [base]
        }
        if !opened {
            opened = true
            if atEnd {
                chunks = [Chunk(key: 0, start: max(0, rows.count - Self.first))]
            } else {
                chunks = [Chunk(key: 0, start: 0)]
                hi = rows.count > Self.first ? Self.first : nil
            }
        }
        let end = min(hi ?? rows.count, rows.count)
        var out: [AgentTurn] = []
        out.reserveCapacity(chunks.count)
        rowsByTurn.removeAll(keepingCapacity: true)
        continuing.removeAll(keepingCapacity: true)
        for (index, chunk) in chunks.enumerated() {
            let upper = min(index + 1 < chunks.count ? chunks[index + 1].start : end, rows.count)
            let range = min(chunk.start, upper)..<upper
            let isLast = index == chunks.count - 1
            let turn: AgentTurn
            if let kept = made[chunk.key], kept.range == range, range.upperBound <= unchanged, !isLast || base.status != .running {
                turn = kept.turn
            } else {
                turn = Self.chunkTurn(base, key: chunk.key, range: range, rows: rows.count, starts: starts, isLast: isLast)
                made[chunk.key] = (turn, range)
            }
            rowsByTurn[turn.id] = rows[range]
            if range.lowerBound > 0 { continuing.insert(turn.id) }
            out.append(turn)
        }
        lastTurnID = out.last?.id
        return out
    }

    /// The rows of chunk turn `id` (nil: not a chunk of this window).
    func rows(of id: String) -> [TurnRow]? { rowsByTurn[id].map(Array.init) }

    /// The chunk turn `id` continues the one above it.
    func continues(_ id: String) -> Bool { continuing.contains(id) }

    /// Chunk `key` of `base`: the items of its rows, its prompt only when it starts at the first
    /// row, running only when it holds the last row.
    private static func chunkTurn(_ base: AgentTurn, key: Int, range: Range<Int>, rows: Int, starts: [Int], isLast: Bool) -> AgentTurn {
        var turn = base
        if key != 0 { turn.id = "\(base.id)~c\(key)" }
        if range.lowerBound > 0 { turn.prompt = "" }
        let first = range.lowerBound < starts.count ? starts[range.lowerBound] : base.items.count
        let last = range.upperBound < starts.count ? starts[range.upperBound] : base.items.count
        turn.items = first < last ? Array(base.items[first..<last]) : []
        if !(range.upperBound >= rows && isLast), turn.status == .running { turn.status = .completed }
        return turn
    }

    /// The next chunk; false once every row is shown.
    func grow() -> Bool {
        guard enabled, opened, !complete else { return false }
        if let top = chunks.first, top.start > 0 {
            chunks.insert(Chunk(key: top.key - 1, start: max(0, top.start - Self.chunk)), at: 0)
        } else if let hi {
            let key = (chunks.last?.key ?? 0) + 1
            chunks.append(Chunk(key: key, start: hi))
            self.hi = hi + Self.chunk >= total ? nil : hi + Self.chunk
        }
        return true
    }
}
#endif
