import Darwin
import Foundation

nonisolated let cmuxTopMemoryDiagnosticDefaultGroupLimit = 12

extension CmuxTopProcessSnapshot {
    func memoryDiagnosticPayload(
        appPID: Int = Int(Darwin.getpid()),
        topGroupLimit: Int = cmuxTopMemoryDiagnosticDefaultGroupLimit,
        attributionByPID: [Int: CmuxTopProcessAttribution] = [:],
        unattributedTTYProcessIDs: Set<Int> = []
    ) -> [String: Any] {
        let appResources = summaryPayload(for: [appPID], rootPIDs: [appPID])
        let appProcess = processesByPID[appPID]
        let descendantPIDs = descendantPIDs(rootPID: appPID, includeRoot: false)
            .filter { processesByPID[$0] != nil }
        // Explicitly attributed surface roots may be reparented to launchd;
        // include those proven PIDs without admitting unproven TTY peers.
        let provenReparentedPIDs = attributionByPID.keys.filter { processID in
            processID > 1 && processID != appPID && processesByPID[processID] != nil
        }
        let childPIDs = Set(descendantPIDs).union(provenReparentedPIDs)
        let excludedTTYProcessIDs = Set(unattributedTTYProcessIDs.filter { processID in
            processID > 1 &&
                processID != appPID &&
                processesByPID[processID] != nil &&
                !childPIDs.contains(processID) &&
                attributionByPID[processID] == nil
        })
        let childSummary = summary(for: childPIDs)
        let descendantSummary = summary(for: Set(descendantPIDs))
        let excludedTTYSummary = summary(for: excludedTTYProcessIDs)
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
                "descendant_rss_bytes": descendantSummary.residentBytes,
                "descendant_process_count": descendantSummary.processCount,
                "proven_owned_rss_bytes": childSummary.residentBytes,
                "recursive_rss_bytes": childSummary.residentBytes,
                "process_count": childSummary.processCount,
                "pids": childSummary.pids,
                "groups": groups,
                "unattributed_tty": [
                    "memory_bytes": excludedTTYSummary.memoryBytes,
                    "resident_bytes": excludedTTYSummary.residentBytes,
                    "rss_bytes": excludedTTYSummary.residentBytes,
                    "process_count": excludedTTYSummary.processCount,
                    "pids": excludedTTYSummary.pids,
                    "ownership": "ambiguous",
                    "reason": CmuxTopProcessOwnershipReason.sameTTYUnproven.rawValue,
                    "os_aggregation": "force-quit-session-aggregation-outside-cmux-control"
                ] as [String: Any]
            ] as [String: Any],
            "summary": memoryDiagnosticSummaryText(
                appFootprintBytes: appProcess?.memoryBytes ?? 0,
                childRSSBytes: childSummary.residentBytes,
                topGroup: topGroup,
                unattributedTTYBytes: excludedTTYSummary.residentBytes,
                unattributedTTYProcessCount: excludedTTYSummary.processCount
            )
        ]
    }

    private func memoryDiagnosticGroups(
        for pids: Set<Int>,
        topGroupLimit: Int,
        attributionByPID: [Int: CmuxTopProcessAttribution]
    ) -> [[String: Any]] {
        var groups: [String: CmuxTopMemoryDiagnosticGroupAccumulator] = [:]
        for pid in pids.sorted() {
            guard let process = processesByPID[pid] else { continue }
            let name = process.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name.isEmpty ? "pid-\(pid)" : name
            let key = displayName.lowercased()
            if groups[key] == nil {
                groups[key] = CmuxTopMemoryDiagnosticGroupAccumulator(id: key, name: displayName)
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
        topGroup: [String: Any]?,
        unattributedTTYBytes: Int64,
        unattributedTTYProcessCount: Int
    ) -> String {
        var summary = String.localizedStringWithFormat(
            String(localized: "memoryDiagnostic.summary.base", defaultValue: "%@ app footprint + %@ child RSS"),
            Self.formatDiagnosticBytes(appFootprintBytes),
            Self.formatDiagnosticBytes(childRSSBytes)
        )
        if let topGroup,
           let name = topGroup["name"] as? String,
           let rssBytes = topGroup["rss_bytes"] as? Int64 ?? (topGroup["rss_bytes"] as? NSNumber)?.int64Value {
            summary += String.localizedStringWithFormat(
                String(localized: "memoryDiagnostic.summary.topGroup", defaultValue: "; top child group: %@ %@"),
                name,
                Self.formatDiagnosticBytes(rssBytes)
            )
            if let groupAttribution = topGroup["group_attribution"] as? [String: Any],
               groupAttribution["kind"] as? String == "common",
               let attribution = groupAttribution["owner"] as? [String: Any],
               let workspace = attribution["workspace_ref"] as? String ?? attribution["workspace_id"] as? String,
               !workspace.isEmpty {
                summary += String.localizedStringWithFormat(
                    String(localized: "memoryDiagnostic.summary.workspace", defaultValue: " from workspace %@"),
                    workspace
                )
            }
        }
        if unattributedTTYProcessCount > 0 {
            summary += String.localizedStringWithFormat(
                String(localized: "memoryDiagnostic.summary.unattributedTTY", defaultValue: "; %@ same-TTY RSS excluded (ownership unproven)"),
                Self.formatDiagnosticBytes(unattributedTTYBytes)
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
