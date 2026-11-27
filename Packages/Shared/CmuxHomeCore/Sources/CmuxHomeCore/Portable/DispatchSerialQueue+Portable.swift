#if !canImport(Darwin)
import Dispatch

/// The `DispatchSerialQueue` surface this package uses (an actor's executor),
/// for platforms whose Dispatch lacks it (the Linux package lane): jobs run
/// one at a time on a serial `DispatchQueue`.
final class DispatchSerialQueue: SerialExecutor, @unchecked Sendable { // crash-allow: immutable after init; DispatchQueue is thread-safe
    private let queue: DispatchQueue
    private static let labelKey = DispatchSpecificKey<String>()

    init(label: String, qos: DispatchQoS = .unspecified) {
        queue = DispatchQueue(label: label, qos: qos)
        queue.setSpecific(key: Self.labelKey, value: label)
    }

    /// The label of the queue running the caller, when it is one of these
    /// (Darwin's `__dispatch_queue_get_label(nil)`, which Linux lacks).
    static var currentLabel: String? { DispatchQueue.getSpecific(key: labelKey) }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
#endif
