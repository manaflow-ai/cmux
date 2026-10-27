import Foundation
import Observation

/// Find in Chat (the Mac's agent chat menu, `menu.agentChat.findInChat`): the chat's prompts
/// and answers searched for a query, every match counted, one current match the transcript
/// scrolls to and marks, stepped with next and previous.
@MainActor
@Observable
public final class AgentChatFind {
    /// One match: the transcript block it is in (`AgentChatFind.Block.key`) and where in the
    /// block's text it starts (0 the top, 1 the end), so a long answer scrolls to it.
    public struct Match: Hashable, Sendable {
        public var block: String
        public var position: Double
    }

    /// A searchable block of the transcript: a prompt bubble or an answer's message.
    public struct Block: Hashable, Sendable {
        /// The prompt's `"<turn id>|prompt"`, or the message row's id (`TurnRow.id`).
        public var key: String
        public var text: String

        public init(key: String, text: String) {
            self.key = key
            self.text = text
        }
    }

    public var query = ""
    public private(set) var matches: [Match] = []
    /// The current match's index in `matches` (nil: none).
    public private(set) var current: Int?
    /// Moves when the person moves to a match (a new query, next, previous), so the transcript
    /// scrolls to it. Output that arrives while the bar is up never moves it.
    public private(set) var step = 0
    /// The newest search (an older one that finishes later is dropped).
    @ObservationIgnored private var generation = 0
    /// The search running now (tests wait on it).
    @ObservationIgnored private(set) var pending: Task<Void, Never>?

    public init() {}

    /// The current match.
    public var currentMatch: Match? { current.map { matches[$0] } }
    /// The block the current match is in.
    public var currentBlock: String? { currentMatch?.block }

    /// "3 of 12", "No results", or nothing before a query.
    public var countText: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let current, !matches.isEmpty else { return "No results" }
        return "\(current + 1) of \(matches.count)"
    }

    /// The prompt bubble's block key.
    public nonisolated static func promptKey(_ turnID: String) -> String { "\(turnID)|prompt" }

    /// The blocks of `turns` in transcript order: each prompt, then its answer's messages
    /// (thoughts and tool rows are folded on the phone, as the Mac's find skips them).
    public nonisolated static func blocks(of turns: [AgentTurn]) -> [Block] {
        var out: [Block] = []
        for turn in turns {
            out.append(Block(key: promptKey(turn.id), text: turn.prompt))
            for row in turn.rows {
                if case .message(_, let markdown) = row { out.append(Block(key: row.id, text: markdown)) }
            }
        }
        return out
    }

    /// Every match of `query` in `blocks`, in order: one per occurrence, ignoring case and
    /// accents. An empty query matches nothing.
    public nonisolated static func matches(of query: String, in blocks: [Block]) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var out: [Match] = []
        for block in blocks {
            let text = block.text
            let length = Double(max(text.count, 1))
            var range = text.startIndex..<text.endIndex
            while let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
                let offset = Double(text.distance(from: text.startIndex, to: found.lowerBound))
                out.append(Match(block: block.key, position: min(1, offset / length)))
                // A match is never empty (the needle is not), so the search always moves on.
                range = found.upperBound..<text.endIndex
            }
        }
        return out
    }

    /// Searches `turns` for the query off the main actor (the blocks are built there too); the
    /// current match becomes the last one (the newest, nearest the bottom where the reader is),
    /// and the transcript goes to it.
    public func search(_ turns: [AgentTurn]) {
        run(turns) { [weak self] found in self?.apply(found, keeping: nil, reveal: true) }
    }

    /// Searches again after the transcript changed: the count follows, the current match stays
    /// (the same occurrence of its block), and the transcript does not move.
    public func refresh(_ turns: [AgentTurn]) {
        let keep = currentMatch.flatMap { match in
            current.map { index in (block: match.block, nth: matches[..<index].filter { $0.block == match.block }.count) }
        }
        run(turns) { [weak self] found in
            guard let self, found != self.matches else { return }
            self.apply(found, keeping: keep, reveal: false)
        }
    }

    private func run(_ turns: [AgentTurn], then done: @escaping @MainActor ([Match]) -> Void) {
        generation &+= 1
        let ticket = generation
        let query = query
        pending = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                Self.matches(of: query, in: Self.blocks(of: turns))
            }.value
            guard let self, self.generation == ticket else { return }
            done(found)
        }
    }

    /// The matches of a search. With `keeping`, the current match is that block's `nth`
    /// occurrence (or its last one) when the block still matches; otherwise the last match.
    func apply(_ found: [Match], keeping: (block: String, nth: Int)?, reveal: Bool) {
        matches = found
        if found.isEmpty {
            current = nil
        } else if let keeping {
            let inBlock = found.indices.filter { found[$0].block == keeping.block }
            current = inBlock.isEmpty ? found.count - 1 : inBlock[min(keeping.nth, inBlock.count - 1)]
        } else {
            current = found.count - 1
        }
        if reveal { step &+= 1 }
    }

    /// Next (down the transcript), wrapping to the first.
    public func next() {
        guard !matches.isEmpty else { return }
        current = ((current ?? -1) + 1) % matches.count
        step &+= 1
    }

    /// Previous (up the transcript), wrapping to the last.
    public func previous() {
        guard !matches.isEmpty else { return }
        current = ((current ?? matches.count) - 1 + matches.count) % matches.count
        step &+= 1
    }
}
