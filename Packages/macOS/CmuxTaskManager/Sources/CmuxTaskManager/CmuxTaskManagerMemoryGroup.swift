public import Foundation

/// A named group of child processes sharing a memory attribution, parsed from
/// a `memory_diagnostic.children.groups` entry. `nil` when the entry has no
/// name or no processes.
public struct CmuxTaskManagerMemoryGroup: Sendable {
    /// Stable group identifier, defaulting to the lowercased name.
    public let id: String
    /// Display name of the group.
    public let name: String
    /// Resident set size of the group in bytes.
    public let rssBytes: Int64
    /// Number of processes in the group (always greater than zero).
    public let processCount: Int
    /// PIDs in the group.
    public let processIds: [Int]
    /// Best-guess workspace/pane/surface attribution, when available.
    public let topAttribution: CmuxTaskManagerMemoryAttribution?

    public init?(_ payload: [String: Any]) {
        let reader = TaskManagerJSONPayloadReader(payload)
        guard let name = reader.string("name") else {
            return nil
        }
        let processCount = reader.int("process_count") ?? 0
        guard processCount > 0 else { return nil }
        self.id = reader.string("id") ?? name.lowercased()
        self.name = name
        self.rssBytes = reader.int64("rss_bytes")
        self.processCount = processCount
        self.processIds = reader.intArray("pids")
        self.topAttribution = CmuxTaskManagerMemoryAttribution(payload["top_attribution"] as? [String: Any])
    }
}
