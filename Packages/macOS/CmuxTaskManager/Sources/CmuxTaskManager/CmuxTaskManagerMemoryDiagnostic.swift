public import Foundation

/// App + child-process memory diagnostic for the Task Manager, parsed from the
/// snapshot `memory_diagnostic` payload. `nil` when the payload is absent.
public struct CmuxTaskManagerMemoryDiagnostic: Sendable {
    /// Human-readable one-line summary, or empty when none.
    public let summary: String
    /// App physical footprint in bytes.
    public let appFootprintBytes: Int64
    /// App resident set size in bytes.
    public let appResidentBytes: Int64
    /// Recursive resident set size of all child processes in bytes.
    public let childRSSBytes: Int64
    /// Total number of child processes.
    public let childProcessCount: Int
    /// Child-process memory groups, largest-first as produced upstream.
    public let groups: [CmuxTaskManagerMemoryGroup]

    public init?(_ payload: [String: Any]?) {
        guard let payload else { return nil }
        let reader = TaskManagerJSONPayloadReader(payload)
        let app = reader.objectOrEmpty("app")
        let children = reader.objectOrEmpty("children")
        self.summary = reader.string("summary") ?? ""
        self.appFootprintBytes = app.int64("physical_footprint_bytes")
        self.appResidentBytes = app.int64("resident_bytes")
        self.childRSSBytes = children.int64("recursive_rss_bytes")
        self.childProcessCount = children.int("process_count") ?? 0
        self.groups = children.objectArray("groups")
            .compactMap(CmuxTaskManagerMemoryGroup.init)
    }
}
