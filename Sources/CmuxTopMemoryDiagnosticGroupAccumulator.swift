import Foundation

/// Builds one command-name memory group and its aggregate ownership classification.
struct CmuxTopMemoryDiagnosticGroupAccumulator {
    private struct AttributionAccumulator {
        let attribution: CmuxTopProcessAttribution
        var rssBytes: Int64 = 0
        var processIDs: [Int] = []

        var displayKey: String {
            [
                attribution.workspaceRef,
                attribution.paneRef,
                attribution.surfaceRef,
                attribution.workspaceID?.uuidString,
                attribution.paneID?.uuidString,
                attribution.surfaceID?.uuidString
            ]
                .compactMap { $0 }
                .joined(separator: "/")
        }

        /// Adds one process to this attribution bucket.
        mutating func append(process: CmuxTopProcessInfo) {
            rssBytes = CmuxTopProcessSnapshot.clampedAdd(rssBytes, process.residentBytes)
            processIDs.append(process.pid)
        }

        /// Serializes the attribution bucket and its process IDs.
        func payload() -> [String: Any] {
            var payload = attribution.payload()
            let sortedProcessIDs = processIDs.sorted()
            payload["rss_bytes"] = rssBytes
            payload["resident_bytes"] = rssBytes
            payload["process_count"] = sortedProcessIDs.count
            payload["pids"] = sortedProcessIDs
            return payload
        }
    }

    let id: String
    let name: String
    var rssBytes: Int64 = 0
    private var processIDs: [Int] = []
    private var attributions: [CmuxTopProcessOwner: AttributionAccumulator] = [:]
    private var attributedProcessCount = 0
    private var commonOwner: CmuxTopProcessOwner?
    private var ownerIdentityKeys: Set<String> = []
    private var workspaceIdentityKeys: Set<String> = []
    private var attributionReasons: Set<String> = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Adds a process and, when available, its ownership evidence.
    mutating func append(
        process: CmuxTopProcessInfo,
        attribution: CmuxTopProcessAttribution?
    ) {
        rssBytes = CmuxTopProcessSnapshot.clampedAdd(rssBytes, process.residentBytes)
        processIDs.append(process.pid)
        guard let attribution else { return }
        attributedProcessCount += 1
        attributionReasons.insert(attribution.reason)
        let owner = attribution.owner
        if let existingCommonOwner = commonOwner {
            commonOwner = existingCommonOwner.commonOwner(with: owner)
        } else if attributedProcessCount == 1 {
            commonOwner = owner
        }
        if let identityKey = owner.identityKey {
            ownerIdentityKeys.insert(identityKey)
        }
        if let workspaceIdentityKey = owner.workspaceIdentityKey {
            workspaceIdentityKeys.insert(workspaceIdentityKey)
        }
        if attributions[owner] == nil {
            attributions[owner] = AttributionAccumulator(attribution: attribution)
        }
        attributions[owner]?.append(process: process)
    }

    /// Serializes the command group and aggregate ownership classification.
    func payload() -> [String: Any] {
        let sortedProcessIDs = processIDs.sorted()
        let attributionPayloads = attributions.values
            .sorted {
                if $0.rssBytes != $1.rssBytes {
                    return $0.rssBytes > $1.rssBytes
                }
                return $0.displayKey < $1.displayKey
            }
            .map { $0.payload() }
        let topAttribution: Any = attributionPayloads.first.map { $0 as Any } ?? NSNull()
        return [
            "id": id,
            "name": name,
            "rss_bytes": rssBytes,
            "resident_bytes": rssBytes,
            "process_count": sortedProcessIDs.count,
            "pids": sortedProcessIDs,
            "group_attribution": groupAttributionPayload(),
            "top_attribution": topAttribution,
            "attributions": attributionPayloads
        ]
    }

    /// Builds the stable group-level ownership and reason payload.
    private func groupAttributionPayload() -> [String: Any] {
        let processCount = processIDs.count
        let unattributedProcessCount = max(0, processCount - attributedProcessCount)
        let sortedReasons = attributionReasons.sorted()
        let reason: String
        if attributedProcessCount == 0 {
            reason = "unattributed"
        } else if sortedReasons.count == 1, let firstReason = sortedReasons.first {
            reason = firstReason
        } else {
            reason = "multiple-evidence"
        }
        let kind: String
        let ownerPayload: Any
        if attributedProcessCount == 0 {
            kind = "unattributed"
            ownerPayload = NSNull()
        } else if unattributedProcessCount > 0 {
            kind = "partial"
            ownerPayload = NSNull()
        } else if let commonOwner {
            kind = "common"
            ownerPayload = CmuxTopProcessAttribution(
                owner: commonOwner,
                reason: reason
            ).payload()
        } else {
            kind = "multiple"
            ownerPayload = NSNull()
        }
        return [
            "kind": kind,
            "owner": ownerPayload,
            "reason": reason,
            "reasons": sortedReasons,
            "workspace_count": workspaceIdentityKeys.count,
            "owner_count": ownerIdentityKeys.count,
            "attributed_process_count": attributedProcessCount,
            "unattributed_process_count": unattributedProcessCount
        ]
    }
}
