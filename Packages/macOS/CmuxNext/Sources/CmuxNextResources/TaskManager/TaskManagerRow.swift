import Foundation

/// One process in the Task Manager: what it does for cmux and its numbers.
public struct TaskManagerRow: Sendable, Equatable, Identifiable {
    /// The process (host and pid); the row's identity across refreshes.
    public var id: ProcessKey
    public var kind: TaskManagerRowKind
    /// What the process serves: the tab titles it works for, else the kind's name.
    public var task: String
    /// The executable name.
    public var name: String
    /// Share of one core over the last interval; nil until a second sample.
    public var cpu: Double?
    public var memoryBytes: UInt64
    /// The tabs the process works for (empty for app, daemon and shared processes).
    public var tabIDs: [String]

    public init(id: ProcessKey, kind: TaskManagerRowKind, task: String, name: String,
                cpu: Double?, memoryBytes: UInt64, tabIDs: [String] = []) {
        self.id = id
        self.kind = kind
        self.task = task
        self.name = name
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.tabIDs = tabIDs
    }

    /// The pid, for sorting and display.
    public var pid: Int32 { id.pid }
    /// CPU for sorting: no value sorts as zero.
    public var cpuSortValue: Double { cpu ?? 0 }
}
