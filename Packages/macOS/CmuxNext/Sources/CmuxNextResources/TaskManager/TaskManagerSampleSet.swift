import Foundation

/// One Task Manager sample: every tab's processes and the shared ones
/// (``ResourceSampleSet`` over ``ResourceTarget/everything``), plus the daemons and the items
/// Memory Saver discarded.
public struct TaskManagerSampleSet: Sendable, Equatable {
    public var resources: ResourceSampleSet
    /// The cmux-tui daemons' processes; their counters are in `resources.samples`.
    public var daemons: [ProcessKey]
    /// The items discarded now, in tab order.
    public var discarded: [TaskManagerDiscardedItem]

    public init(resources: ResourceSampleSet = .empty, daemons: [ProcessKey] = [],
                discarded: [TaskManagerDiscardedItem] = []) {
        self.resources = resources
        self.daemons = daemons
        self.discarded = discarded
    }

    public static let empty = TaskManagerSampleSet()
}
