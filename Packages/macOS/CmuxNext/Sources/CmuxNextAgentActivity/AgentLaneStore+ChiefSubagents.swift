extension AgentLaneStore {
    /// The Chief's agents that have a session in this store (its acpmux's `optchat-sub-<home>-a<n>`
    /// sessions), by their Chief id (`a<n>`). Observes ``names`` only, so it changes when a subagent's
    /// session comes or goes, not on each step of its output. Home reads it to see a queued agent start.
    public var chiefSubagentPeers: Set<String> {
        Set(names.compactMap(chiefSubagentPeer(name:)))
    }
}

/// The Chief id (`a<n>`) of a subagent session's name (`optchat-sub-<home>-a<n>`, `-<m>` after it when
/// acpmux deduped the name); nil for any other session.
private func chiefSubagentPeer(name: String) -> String? {
    let parts = name.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count > 3, parts[0] == "optchat", parts[1] == "sub", parts[3].first == "a",
          let number = Int(parts[3].dropFirst()) else { return nil }
    return "a\(number)"
}
