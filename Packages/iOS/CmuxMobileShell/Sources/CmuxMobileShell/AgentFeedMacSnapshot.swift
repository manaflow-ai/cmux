import CmuxMobileShellModel

/// Last authoritative workstream snapshot received from one Mac.
struct AgentFeedMacSnapshot {
    var pages: MobileAgentFeedPageAccumulator
    var items: [MobileAgentFeedItem]

    var revision: UInt64 { pages.revision }
    var nextCursor: String? { pages.nextCursor }
    var hasMore: Bool { pages.hasMore }
}
