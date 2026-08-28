import Foundation

/// Decodes one command-name aggregate from the memory diagnostic payload.
struct CmuxTaskManagerMemoryGroup: Sendable {
    let id: String
    let name: String
    let rssBytes: Int64
    let processCount: Int
    let processIds: [Int]
    let attribution: CmuxTaskManagerMemoryGroupAttribution
    let attributionReason: String?

    init?(_ payload: [String: Any]) {
        guard let name = CmuxTaskManagerMemoryDiagnostic.string(payload["name"]) else {
            return nil
        }
        let processCount = CmuxTaskManagerMemoryDiagnostic.int(payload["process_count"]) ?? 0
        guard processCount > 0 else { return nil }
        self.id = CmuxTaskManagerMemoryDiagnostic.string(payload["id"]) ?? name.lowercased()
        self.name = name
        self.rssBytes = CmuxTaskManagerMemoryDiagnostic.int64(payload["rss_bytes"])
        self.processCount = processCount
        self.processIds = CmuxTaskManagerMemoryDiagnostic.intArray(payload["pids"])
        let topAttribution = CmuxTaskManagerMemoryAttribution(payload["top_attribution"] as? [String: Any])
        let groupAttributionPayload = payload["group_attribution"] as? [String: Any] ?? [:]
        self.attributionReason = CmuxTaskManagerMemoryDiagnostic.string(groupAttributionPayload["reason"])
        self.attribution = CmuxTaskManagerMemoryGroupAttribution(
            groupAttributionPayload
        )
            ?? topAttribution.map(CmuxTaskManagerMemoryGroupAttribution.common)
            ?? .unattributed
    }
}
