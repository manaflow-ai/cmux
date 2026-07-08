import Darwin
import Foundation

nonisolated let cmuxTopMemoryDiagnosticDefaultGroupLimit = 12

nonisolated struct CmuxTopProcessAttribution: Hashable, Sendable {
    let workspaceID: UUID?
    let workspaceRef: String?
    let paneID: UUID?
    let paneRef: String?
    let surfaceID: UUID?
    let surfaceRef: String?
    let surfaceType: String?
    let reason: String

    func payload() -> [String: Any] {
        [
            "workspace_id": workspaceID?.uuidString as Any? ?? NSNull(),
            "workspace_ref": workspaceRef as Any? ?? NSNull(),
            "pane_id": paneID?.uuidString as Any? ?? NSNull(),
            "pane_ref": paneRef as Any? ?? NSNull(),
            "surface_id": surfaceID?.uuidString as Any? ?? NSNull(),
            "surface_ref": surfaceRef as Any? ?? NSNull(),
            "surface_type": surfaceType as Any? ?? NSNull(),
            "reason": reason
        ]
    }
}

nonisolated extension CmuxTopProcessSnapshot {
    func memoryDiagnosticPayload(
        appPID: Int = Int(Darwin.getpid()),
        topGroupLimit: Int = cmuxTopMemoryDiagnosticDefaultGroupLimit,
        attributionByPID: [Int: CmuxTopProcessAttribution] = [:]
    ) -> [String: Any] {
        let appResources = summaryPayload(for: [appPID], rootPIDs: [appPID])
        let appProcess = processesByPID[appPID]
        let childPIDs = descendantPIDs(rootPID: appPID, includeRoot: false)
            .filter { processesByPID[$0] != nil }
        let childSummary = summary(for: childPIDs)
        let groups = memoryDiagnosticGroups(
            for: childPIDs,
            topGroupLimit: topGroupLimit,
            attributionByPID: attributionByPID
        )
        let topGroup = groups.first

        return [
            "sampled_at": ISO8601DateFormatter().string(from: sampledAt),
            "app": [
                "pid": appPID,
                "name": appProcess?.name ?? "cmux",
                "path": appProcess?.path as Any? ?? NSNull(),
                "resources": appResources,
                "physical_footprint_bytes": appProcess?.memoryBytes ?? 0,
                "resident_bytes": appProcess?.residentBytes ?? 0,
                "memory_source": appProcess?.memorySource.rawValue ?? CmuxTopProcessMemorySource.unavailable.rawValue,
                "resident_memory_source": appProcess?.residentMemorySource.rawValue ?? CmuxTopProcessMemorySource.unavailable.rawValue
            ] as [String: Any],
            "children": [
                "root_pid": appPID,
                "recursive_rss_bytes": childSummary.residentBytes,
                "process_count": childSummary.processCount,
                "pids": childSummary.pids,
                "groups": groups
            ] as [String: Any],
            "summary": memoryDiagnosticSummaryText(
                appFootprintBytes: appProcess?.memoryBytes ?? 0,
                childRSSBytes: childSummary.residentBytes,
                topGroup: topGroup
            )
        ]
    }

    private struct MemoryDiagnosticGroupAccumulator {
        let id: String
        let name: String
        var rssBytes: Int64 = 0
        var processIDs: [Int] = []
        var attributions: [CmuxTopProcessAttribution: MemoryDiagnosticAttributionAccumulator] = [:]

        mutating func append(
            process: CmuxTopProcessInfo,
            attribution: CmuxTopProcessAttribution?
        ) {
            rssBytes = CmuxTopProcessSnapshot.clampedAdd(rssBytes, process.residentBytes)
            processIDs.append(process.pid)
            guard let attribution else { return }
            if attributions[attribution] == nil {
                attributions[attribution] = MemoryDiagnosticAttributionAccumulator(attribution: attribution)
            }
            attributions[attribution]?.append(process: process)
        }

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
                "top_attribution": topAttribution,
                "attributions": attributionPayloads
            ]
        }
    }

    private struct MemoryDiagnosticAttributionAccumulator {
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

        mutating func append(process: CmuxTopProcessInfo) {
            rssBytes = CmuxTopProcessSnapshot.clampedAdd(rssBytes, process.residentBytes)
            processIDs.append(process.pid)
        }

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

    private func memoryDiagnosticGroups(
        for pids: Set<Int>,
        topGroupLimit: Int,
        attributionByPID: [Int: CmuxTopProcessAttribution]
    ) -> [[String: Any]] {
        var groups: [String: MemoryDiagnosticGroupAccumulator] = [:]
        let agentDefinitions = codingAgentDefinitionsByPID(for: pids)
        for pid in pids.sorted() {
            guard let process = processesByPID[pid] else { continue }
            let displayName = agentDefinitions[pid]?.displayName
                ?? cmuxTopCanonicalProcessName(name: process.name, path: process.path)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            let groupName = displayName.isEmpty ? "pid-\(pid)" : displayName
            // Case-insensitive key so casing variants of one executable share a group;
            // id/name keep the first-seen display casing.
            let key = groupName.lowercased()
            if groups[key] == nil {
                groups[key] = MemoryDiagnosticGroupAccumulator(id: groupName, name: groupName)
            }
            groups[key]?.append(
                process: process,
                attribution: nearestCMUXAttribution(
                    for: pid,
                    attributionByPID: attributionByPID
                )
            )
        }

        let limit = max(1, topGroupLimit)
        return groups.values
            .sorted {
                if $0.rssBytes != $1.rssBytes {
                    return $0.rssBytes > $1.rssBytes
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(limit)
            .map { $0.payload() }
    }

    private func nearestCMUXAttribution(
        for pid: Int,
        attributionByPID: [Int: CmuxTopProcessAttribution]
    ) -> CmuxTopProcessAttribution? {
        var visited: Set<Int> = []
        var currentPID = pid
        while currentPID > 0, visited.insert(currentPID).inserted {
            if let attribution = attributionByPID[currentPID] {
                return attribution
            }
            guard let process = processesByPID[currentPID] else { return nil }
            if process.cmuxWorkspaceID != nil || process.cmuxSurfaceID != nil {
                return CmuxTopProcessAttribution(
                    workspaceID: process.cmuxWorkspaceID,
                    workspaceRef: nil,
                    paneID: nil,
                    paneRef: nil,
                    surfaceID: process.cmuxSurfaceID,
                    surfaceRef: nil,
                    surfaceType: nil,
                    reason: process.cmuxAttributionReason ?? "cmux-process-scope"
                )
            }
            currentPID = process.parentPID
        }
        return nil
    }

    private func memoryDiagnosticSummaryText(
        appFootprintBytes: Int64,
        childRSSBytes: Int64,
        topGroup: [String: Any]?
    ) -> String {
        var summary = String.localizedStringWithFormat(
            String(localized: "memoryDiagnostic.summary.base", defaultValue: "%@ app footprint + %@ child RSS"),
            Self.formatDiagnosticBytes(appFootprintBytes),
            Self.formatDiagnosticBytes(childRSSBytes)
        )
        guard let topGroup,
              let name = topGroup["name"] as? String,
              let rssBytes = topGroup["rss_bytes"] as? Int64 ?? (topGroup["rss_bytes"] as? NSNumber)?.int64Value else {
            return summary
        }

        summary += String.localizedStringWithFormat(
            String(localized: "memoryDiagnostic.summary.topGroup", defaultValue: "; top child group: %@ %@"),
            name,
            Self.formatDiagnosticBytes(rssBytes)
        )
        if let attribution = topGroup["top_attribution"] as? [String: Any],
           let workspace = attribution["workspace_ref"] as? String ?? attribution["workspace_id"] as? String,
           !workspace.isEmpty {
            summary += String.localizedStringWithFormat(
                String(localized: "memoryDiagnostic.summary.workspace", defaultValue: " from workspace %@"),
                workspace
            )
        }
        return summary
    }

    private static func formatDiagnosticBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = .useAll
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
