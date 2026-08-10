import CmuxMobileShellModel

/// Last authoritative workstream snapshot received from one Mac.
struct AgentFeedMacSnapshot {
    var revision: UInt64
    var items: [MobileAgentFeedItem]
}
