/// One call site where a thread waited on a queue of a lower quality of service than its own, as
/// ``BlockingDetector/qosInversions`` lists it for `debug.blocking` (Debug and bench-checks builds).
///
/// The wait holds the higher-QoS thread behind work the system schedules below it: the main thread
/// (user-interactive) in `blockingSync` on a utility queue waits for everything queued there before it, at
/// utility priority. Xcode's Thread Performance Checker reports the same case ("a thread running at a higher QoS
/// waiting on a lower QoS"), and Chrome states the rule for its tasks: work a higher-priority sequence waits for
/// must not be posted below it (base/task/task_traits.h, `TaskPriority`).
public struct BlockingQoSInversion: Sendable, Equatable {
    /// The waiting seam's call site: `Module/File.swift:line`.
    public var location: String
    /// The waiting thread's class at the first inversion at this site (`qos_class_self()`).
    public var waiter: ThreadQoS
    /// The class of the queue it waited on at that inversion.
    public var target: ThreadQoS
    /// How many inversions at this site since launch (or since ``BlockingDetector/resetCounts()``).
    public var count: Int

    /// Makes the value from its parts.
    public init(location: String, waiter: ThreadQoS, target: ThreadQoS, count: Int) {
        self.location = location
        self.waiter = waiter
        self.target = target
        self.count = count
    }
}
