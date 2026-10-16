import Foundation

/// Bounded telemetry derived from a single process snapshot without identity strings.
public struct ProcessMemoryDiagnostics: Sendable {
    /// Sum of resident bytes; shared pages may be counted more than once.
    public let childRSSBytes: Int64
    /// Sum of measured footprint or fallback RSS.
    public let childAccountedBytes: Int64
    /// Number of contributions using RSS instead of footprint.
    public let footprintFallbackCount: Int
    /// Number of distinct descendant contributions supplied by the caller.
    public let descendantCount: Int
    /// Contributions without an accounted-byte measurement.
    public let missingMemoryCount: Int
    /// Contributions without a resident-byte measurement.
    public let missingRSSCount: Int
    /// Whether the caller captured all topology, including the root.
    public let enumerationComplete: Bool
    /// Process-table entries whose topology could not be read.
    public let enumerationMissingCount: Int
    /// RSS grouped into fixed family names, never arbitrary process names.
    public let familyRSSBytes: [String: Int64]
    /// At most five workspace RSS totals, largest first, without identity.
    public let workspaceRSSBytesByRank: [Int64]

    /// Reduces one snapshot in linear time without retaining names or identities.
    /// - Parameters:
    ///   - descendants: Unique descendant records from one captured topology.
    ///   - enumerationComplete: Whether that topology is complete.
    ///   - enumerationMissingCount: Number of unreadable process-table records.
    public init<Records: Sequence>(
        descendants: Records,
        enumerationComplete: Bool,
        enumerationMissingCount: Int
    ) where Records.Element == ProcessMemorySample {
        self.enumerationComplete = enumerationComplete
        self.enumerationMissingCount = max(0, enumerationMissingCount)
        var families: [String: Int64] = [:]
        var workspaces: [UUID: Int64] = [:]
        var rss: Int64 = 0
        var accounted: Int64 = 0
        var footprintFallbacks = 0
        var missingMemory = 0
        var missingRSS = 0
        var count = 0
        for process in descendants {
            count += 1
            rss = Self.clampedAdd(rss, max(0, process.residentBytes ?? 0))
            accounted = Self.clampedAdd(accounted, max(0, process.physicalFootprintBytes ?? process.residentBytes ?? 0))
            if process.physicalFootprintBytes == nil, process.residentBytes != nil { footprintFallbacks += 1 }
            if process.physicalFootprintBytes == nil, process.residentBytes == nil { missingMemory += 1 }
            if process.residentBytes == nil { missingRSS += 1 }
            let family = Self.family(process.name)
            families[family] = Self.clampedAdd(
                families[family, default: 0], max(0, process.residentBytes ?? 0)
            )
            if let workspaceID = process.workspaceID {
                workspaces[workspaceID] = Self.clampedAdd(
                    workspaces[workspaceID, default: 0], max(0, process.residentBytes ?? 0)
                )
            }
        }
        childRSSBytes = rss
        childAccountedBytes = accounted
        footprintFallbackCount = footprintFallbacks
        descendantCount = count
        missingMemoryCount = missingMemory
        missingRSSCount = missingRSS
        familyRSSBytes = families
        // At most five retained values: O(workspaces) time and constant ranking space.
        var leaders: [Int64] = []
        for value in workspaces.values {
            let index = leaders.firstIndex(where: { value > $0 }) ?? leaders.count
            guard index < 5 else { continue }
            leaders.insert(value, at: index)
            if leaders.count > 5 { leaders.removeLast() }
        }
        workspaceRSSBytesByRank = leaders
    }

    /// Returns bounded, JSON-compatible diagnostics without process or workspace identity.
    /// - Returns: Counts, byte totals, fixed family labels and anonymous contribution ranks.
    public func payload() -> [String: Any] {
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

    private static func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
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
