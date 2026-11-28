import Foundation

/// The session tree's chat history rule (`sidebar_chat_history` `make`, cmux-layout-reducer's
/// `sidebar_chat_history.rs`): which chats Pinned and Earlier list, and whether Earlier has more. One call per index
/// update; the heights the layout reads per pass stay in Swift.
nonisolated enum RustSidebarChatHistory {
    private struct Chat: Codable {
        let id: String
        var title = ""
        var updated_at = 0.0
        var harness: String?

        init(_ chat: SidebarHistoryChat) {
            id = chat.id
            title = chat.title
            updated_at = chat.updatedAt.timeIntervalSince1970
            harness = chat.harness
        }

        private enum CodingKeys: String, CodingKey { case id, title, updated_at, harness }

        init(from decoder: any Decoder) throws {
            id = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .id)
        }
    }

    private struct MakeRequest: Encodable {
        let op = "make"
        let newest: [Chat]
        let known: [String: Chat]
        let live: [String]
        let pinned: [String]
        let limit: Int
        let folded: Bool
        let more: Bool
        let loading: Bool
    }

    private struct History: Decodable {
        let pinned: [Chat]
        let earlier: [Chat]
        let has_earlier: Bool
        let has_more: Bool
    }

    private struct MakeReply: Decodable { let history: History }

    /// The history of `newest` as ``SidebarChatHistoryState/make(newest:chat:live:pinned:limit:folded:more:loading:)``
    /// documents it. `newest` is read lazily, only as far as the page needs (the rule never reads past it), and the
    /// reply's chats map back to the values read, so nothing round-trips through JSON. A refused call lists nothing
    /// but keeps the fold and Loading row.
    static func make(newest: some Sequence<SidebarHistoryChat>, chat: (String) -> SidebarHistoryChat?, live: Set<String>,
                     pinned: [String], limit: Int, folded: Bool, more: Bool, loading: Bool) -> SidebarChatHistoryState {
        // The page: every chat up to the `wanted`-th one Earlier may list (the first, folded or with no room, which
        // says whether Earlier has one at all).
        let skipped = live.union(pinned)
        let wanted = folded ? 1 : max(1, limit)
        var page: [SidebarHistoryChat] = [], listable = 0
        for item in newest {
            page.append(item)
            if !skipped.contains(item.id) { listable += 1 }
            if listable == wanted { break }
        }
        var known: [String: SidebarHistoryChat] = [:]
        for key in pinned where known[key] == nil { known[key] = chat(key) }
        let request = MakeRequest(newest: page.map(Chat.init), known: known.mapValues(Chat.init), live: live.sorted(),
                                  pinned: pinned, limit: limit, folded: folded, more: more, loading: loading)
        guard let history = RustSidebarClient.call("sidebar_chat_history", request, as: MakeReply.self)?.history else {
            return SidebarChatHistoryState(earlierFolded: folded, loading: loading)
        }
        // Earlier is an ordered subsequence of the page: take each chat read, in order.
        var earlier: [SidebarHistoryChat] = [], next = history.earlier.makeIterator(), want = next.next()
        for item in page where item.id == want?.id {
            earlier.append(item)
            want = next.next()
        }
        return SidebarChatHistoryState(pinned: history.pinned.compactMap { known[$0.id] }, earlier: earlier,
                                       hasEarlier: history.has_earlier, hasMore: history.has_more,
                                       earlierFolded: folded, loading: loading)
    }
}
