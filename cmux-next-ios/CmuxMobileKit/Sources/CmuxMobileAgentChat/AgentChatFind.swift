import CmuxMobileMarkdown
import Foundation
import Observation

/// Find in Chat (the Mac's agent chat menu, `menu.agentChat.findInChat`): the chat's prompts
/// and answers searched for a query, every match counted, one current match the transcript
/// scrolls to and marks, stepped with next and previous.
@MainActor
@Observable
public final class AgentChatFind {
    /// One match: the transcript block it is in (`AgentChatFind.Block.key`) and where in the
    /// block's text it starts (0 the top, 1 the end), so a long block scrolls near it.
    public struct Match: Hashable, Sendable {
        public var block: String
        public var position: Double
    }

    /// A searchable block of the transcript: a prompt bubble, or one rendered block (paragraph,
    /// heading, list, code card, table, quote) of an answer's message, so a match scrolls to
    /// the block that draws it.
    public struct Block: Hashable, Sendable {
        /// The prompt's `"<turn id>|prompt"`, or `blockKey(row:block:)` of a message's block.
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
    /// The newest transcript a refresh asked for while a search ran: searched once that one ends,
    /// so streamed output costs at most one search at a time, never one per chunk.
    @ObservationIgnored private var queuedRefresh: [AgentTurn]?
    /// A search or refresh is running.
    @ObservationIgnored private var busy = false

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

    /// The key of a message row's (`TurnRow.id`) markdown block (`MarkdownBlock.id`).
    public nonisolated static func blockKey(row: String, block: Int) -> String { "\(row)|\(block)" }

    /// The blocks of `turns` in transcript order: each prompt, then its answer's messages, one
    /// block per markdown block the transcript draws (thoughts and tool rows are folded on the
    /// phone, as the Mac's find skips them).
    public nonisolated static func blocks(of turns: [AgentTurn]) -> [Block] {
        var out: [Block] = []
        for turn in turns {
            out.append(Block(key: promptKey(turn.id), text: turn.prompt))
            for row in turn.rows {
                guard case .message(_, let markdown) = row else { continue }
                for block in MarkdownDocument(parsing: markdown).blocks {
                    out.append(Block(key: blockKey(row: row.id, block: block.id), text: text(of: block.kind)))
                }
            }
        }
        return out
    }

    /// The text a markdown block draws (its inline markers left in, as the query may name them).
    nonisolated static func text(of kind: MarkdownBlock.Kind) -> String {
        switch kind {
        case .heading(_, let text), .paragraph(let text), .quote(let text), .math(let text): text
        case .list(let list): list.items.map(\.text).joined(separator: "\n")
        case .code(_, let code, _): code
        case .table(let table): table.plainText
        case .rule: ""
        }
    }

    /// What the search reads, cheaply summed up: it changes when a turn arrives or goes, when
    /// the newest turn's prompt, items or status change, and when its newest item's text grows
    /// (a streamed chunk replaces the last message's text in place, with no new item). O(1) per
    /// change: lengths only, never the text itself.
    public struct Revision: Hashable, Sendable {
        var turns: Int
        var firstTurn: String?
        var lastTurn: String?
        var lastStatus: AgentTurn.Status?
        var lastItems: Int
        var lastItem: String?
        var lastItemLength: Int
        var lastPromptLength: Int
    }

    public nonisolated static func revision(of turns: [AgentTurn]) -> Revision {
        let last = turns.last
        let item = last?.items.last
        // Thoughts are not searched: only a message's growth counts.
        var length = 0
        if case .message(_, let markdown)? = item { length = markdown.utf8.count }
        return Revision(turns: turns.count, firstTurn: turns.first?.id, lastTurn: last?.id, lastStatus: last?.status,
                        lastItems: last?.items.count ?? 0, lastItem: item?.id, lastItemLength: length,
                        lastPromptLength: last?.prompt.utf8.count ?? 0)
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
        // A new query supersedes a running refresh (its result is dropped by the generation);
        // output that arrives while it runs is searched after it, so its reveal is never lost.
        queuedRefresh = nil
        busy = true
        run(turns) { [weak self] found in
            guard let self else { return }
            self.apply(found, keeping: nil, reveal: true)
            self.finished()
        }
    }

    /// Searches again after the transcript changed: the count follows, the current match stays
    /// (the same occurrence of its block), and the transcript does not move. While a search
    /// or refresh runs, later refreshes collapse into one run of the newest transcript after it.
    public func refresh(_ turns: [AgentTurn]) {
        if busy {
            queuedRefresh = turns
            return
        }
        busy = true
        run(turns) { [weak self] found in
            guard let self else { return }
            // The current match as it is now: Next and Previous taps made while this ran stay.
            if found != self.matches { self.apply(found, keeping: self.currentOccurrence, reveal: false) }
            self.finished()
        }
    }

    /// The current match as its block and which occurrence in that block it is.
    private var currentOccurrence: (block: String, nth: Int)? {
        currentMatch.flatMap { match in
            current.map { index in (block: match.block, nth: matches[..<index].filter { $0.block == match.block }.count) }
        }
    }

    /// The running search ended: the newest queued transcript, if any, is searched next.
    private func finished() {
        busy = false
        if let next = queuedRefresh {
            queuedRefresh = nil
            refresh(next)
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
