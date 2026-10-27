import Foundation
import Observation

/// Find in Chat (the Mac's agent chat menu, `menu.agentChat.findInChat`): the chat's prompts
/// and answers searched for a query, every match counted, one current match the transcript
/// scrolls to and marks, stepped with next and previous.
@MainActor
@Observable
public final class AgentChatFind {
    /// One match: the transcript block it is in (`AgentChatFind.Block.key`).
    public struct Match: Hashable, Sendable {
        public var block: String
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
    /// Moves when the current match changes, so the transcript scrolls to it even when the
    /// same block is current again.
    public private(set) var step = 0
    /// The newest search (an older one that finishes later is dropped).
    @ObservationIgnored private var generation = 0

    public init() {}

    /// The block the current match is in.
    public var currentBlock: String? { current.map { matches[$0].block } }

    /// "3 of 12", "No results", or nothing before a query.
    public var countText: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let current, !matches.isEmpty else { return "No results" }
        return "\(current + 1) of \(matches.count)"
    }

    /// The prompt bubble's block key.
    public static func promptKey(_ turnID: String) -> String { "\(turnID)|prompt" }

    /// The blocks of `turns` in transcript order.
    public static func blocks(of turns: [AgentTurn]) -> [Block] {
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
            var range = block.text.startIndex..<block.text.endIndex
            while let found = block.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
                out.append(Match(block: block.key))
                // A match is never empty (the needle is not), so the search always moves on.
                range = found.upperBound..<block.text.endIndex
            }
        }
        return out
    }

    /// Searches `turns` for the query, off the main actor; the current match becomes the
    /// last one (the newest, nearest the bottom where the reader is), as a find bar starts
    /// from the reader's place.
    public func search(_ turns: [AgentTurn]) {
        generation &+= 1
        let ticket = generation
        let blocks = Self.blocks(of: turns)
        let query = query
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.matches(of: query, in: blocks) }.value
            guard let self, self.generation == ticket else { return }
            self.apply(found, keeping: nil)
        }
    }

    /// The matches of a search: the current one is the last, unless `keeping` names a block
    /// that still has one (output that arrived while the bar is open moves nothing).
    func apply(_ found: [Match], keeping block: String?) {
        matches = found
        if found.isEmpty {
            current = nil
        } else if let block, let index = found.lastIndex(where: { $0.block == block }) {
            current = index
        } else {
            current = found.count - 1
        }
        step &+= 1
    }

    /// Searches again after the transcript changed, keeping the current block when it still matches.
    public func refresh(_ turns: [AgentTurn]) {
        generation &+= 1
        let ticket = generation
        let blocks = Self.blocks(of: turns)
        let query = query
        let keep = currentBlock
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.matches(of: query, in: blocks) }.value
            guard let self, self.generation == ticket else { return }
            let unchanged = found == self.matches
            if unchanged { return }
            self.apply(found, keeping: keep)
        }
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
