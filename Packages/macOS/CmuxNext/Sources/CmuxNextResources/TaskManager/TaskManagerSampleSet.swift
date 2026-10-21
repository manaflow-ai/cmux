import Foundation

/// One Task Manager sample: every tab's processes and the shared ones
/// (``ResourceSampleSet`` over ``ResourceTarget/everything``), plus the daemons.
public struct TaskManagerSampleSet: Sendable, Equatable {
    public var resources: ResourceSampleSet
    /// The cmux-tui daemons' processes; their counters are in `resources.samples`.
    public var daemons: [ProcessKey]

    public init(resources: ResourceSampleSet = .empty, daemons: [ProcessKey] = []) {
        self.resources = resources
        self.daemons = daemons
    }

    public static let empty = TaskManagerSampleSet()
}
