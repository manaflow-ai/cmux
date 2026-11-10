public import CmuxNextAgentActivity
public import CmuxNextBridge
import Foundation

/// One page of the watch's session list, decoded off the main actor. acpmux sends a list too
/// large for one message in pages by size (`hub/session_pages.rs`), the first as the watch's
/// result and each with the `nextCursor` of the rest; the feed reads the rest with
/// `_acpmux/sessions {cursor}` (``AgentTurnStateFeed/pageRequest(cursor:)``) and lays each page
/// over the first, so a chat past the first page has its state too.
public nonisolated struct AgentWatchPage: Sendable {
    public var states = AgentTurnStates()
    public var lastMessages: [String: String] = [:]
    public var muted: Set<String> = []
    public var titles: [String: String] = [:]
    public var generatedTitles: [String: String] = [:]
    public var details: [String: AgentChatDetail] = [:]
    public var lanes: [String: AgentActivityLane] = [:]
    public var startedBy: [String: String] = [:]
    public var sessionNames: [String: String] = [:]
    /// Each peer's row of a session id (chats of other machines), by session id, then by peer.
    public var peers: [String: [String: AgentPeerRow]] = [:]
    /// Where the rest of the list starts; nil on its last page.
    public var next: String?

    public init() {}

    /// The page in a `_acpmux/watch` or `_acpmux/sessions` result.
    public init(result: [String: Any]) {
        states.reset(result)
        lastMessages = AgentTurnStates.lastMessages(result)
        muted = AgentTurnStates.muted(result: result)
        titles = AgentTurnStates.titles(result)
        generatedTitles = AgentTurnStates.titles(result, includingPrompt: false)
        details = AgentChatDetail.details(result)
        lanes = AgentTurnStateFeed.Message.lanes(result)
        startedBy = AgentTurnStateStore.startedBy(result)
        sessionNames = AgentTurnStates.sessionNames(result)
        peers = AgentPeerRow.rows(result)
        next = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Lays `later`, the next page of the same list, over this one.
    public mutating func merge(_ later: AgentWatchPage) {
        states.merge(later.states)
        lastMessages.merge(later.lastMessages) { $1 }
        muted.formUnion(later.muted)
        titles.merge(later.titles) { $1 }
        generatedTitles.merge(later.generatedTitles) { $1 }
        details.merge(later.details) { $1 }
        lanes.merge(later.lanes) { $1 }
        startedBy.merge(later.startedBy) { $1 }
        sessionNames.merge(later.sessionNames) { $1 }
        peers.merge(later.peers) { $0.merging($1) { $1 } }
        next = later.next
    }
}

extension AgentTurnStateFeed {
    /// The most later pages one watch result follows (byte-sized pages: far past any real list).
    static let watchPages = 200

    /// `_acpmux/sessions` from `cursor` on (id 4): the rest of a watch result too large for one
    /// message, as an acpmux peer link reads it (`peer.rs` `watch_pages`).
    static func pageRequest(cursor: String) -> Data {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 4, "method": "_acpmux/sessions", "params": ["cursor": cursor]]
        var line = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        line.append(0x0A)
        return line
    }
}
