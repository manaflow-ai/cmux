import Foundation

/// Bounded telemetry derived from a single process snapshot without identity strings.
struct MemoryResourceDiagnostics: Sendable {
    let childRSSBytes: Int64
    let childAccountedBytes: Int64
    let footprintFallbackCount: Int
    let descendantCount: Int
    let missingMemoryCount: Int
    let missingRSSCount: Int
    let enumerationComplete: Bool
    let enumerationMissingCount: Int
    let familyRSSBytes: [String: Int64]
    let workspaceRSSBytesByRank: [Int64]

    init(snapshot: CmuxTopProcessSnapshot, appPID: Int) {
        let pids = snapshot.descendantPIDs(rootPID: appPID, includeRoot: false)
        let summary = snapshot.summary(for: pids)
        childRSSBytes = summary.residentBytes
        childAccountedBytes = summary.memoryBytes
        footprintFallbackCount = summary.memorySourceFallbackPIDs.count
        descendantCount = summary.processCount
        missingMemoryCount = summary.missingPIDs.count + summary.unavailableMemoryPIDs.count
        missingRSSCount = summary.missingPIDs.count + summary.unavailableResidentMemoryPIDs.count
        enumerationComplete = snapshot.enumerationIsComplete && snapshot.process(pid: appPID) != nil
        enumerationMissingCount = snapshot.enumerationMissingProcessCount

        var families: [String: Int64] = [:]
        var workspaces: [UUID: Int64] = [:]
        for pid in pids {
            guard let process = snapshot.process(pid: pid) else { continue }
            let family = Self.family(process.name)
            families[family] = CmuxTopProcessSnapshot.clampedAdd(
                families[family, default: 0], max(0, process.residentBytes)
            )
            if let workspaceID = process.cmuxWorkspaceID {
                workspaces[workspaceID] = CmuxTopProcessSnapshot.clampedAdd(
                    workspaces[workspaceID, default: 0], max(0, process.residentBytes)
                )
            }
        }
        familyRSSBytes = families
        workspaceRSSBytesByRank = Array(workspaces.values.sorted(by: >).prefix(5))
    }

    func payload() -> [String: Any] {
        [
            "source": "descendant_process_tree",
            "rss_bytes": childRSSBytes,
            "accounted_bytes": childAccountedBytes,
            "physical_footprint_fallback_count": footprintFallbackCount,
            "unique_descendant_count": descendantCount,
            "missing_memory_count": missingMemoryCount,
            "missing_rss_count": missingRSSCount,
            "enumeration_complete": enumerationComplete,
            "enumeration_missing_process_count": enumerationMissingCount,
            "family_rss_bytes": familyRSSBytes,
            // Ranks are scoped to this sample. No stable workspace ID, title,
            // directory, arbitrary process name, command or argv leaves the app.
            "top_workspace_rss_bytes": workspaceRSSBytesByRank,
            "workspace_attribution": "inherited_cmux_scope_only"
        ]
    }

    private static func family(_ name: String) -> String {
        switch name.lowercased() {
        case "codex": return "codex"
        case "claude": return "claude"
        case "node", "nodejs", "bun", "deno": return "javascript_runtime"
        case let value where value.hasPrefix("com.apple.webk") || value == "webkit.webcontent":
            return "webkit"
        case "zsh", "bash", "sh", "fish": return "shell"
        default: return "other"
        }
    }
}
