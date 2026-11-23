public import Foundation

extension AgentLaneStore {
    /// The Chief's agents that have a session in this store (its acpmux's `optchat-sub-<home>-a<n>`
    /// sessions), by their Chief id (`a<n>`). Observes ``names`` only, so it changes when a subagent's
    /// session comes or goes, not on each step of its output. Home reads it to see a queued agent start.
    public var chiefSubagentPeers: Set<String> {
        Set(names.compactMap(chiefSubagentPeer(name:)))
    }

    /// When each of the Chief's agents' newest session began (``sessionStarts``), by Chief id (`a<n>`): an agent
    /// with a deduped second session (`-2`) counts from the newer one. Observes ``sessionStarts`` only, so a step of
    /// a subagent's output leaves it alone. Home's agent pills count from it (user 2026-11-20).
    public var chiefSubagentStarts: [String: Date] {
        var starts: [String: Date] = [:]
        for (name, start) in sessionStarts {
            guard let peer = chiefSubagentPeer(name: name) else { continue }
            starts[peer] = max(starts[peer] ?? start, start)
        }
        return starts
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
