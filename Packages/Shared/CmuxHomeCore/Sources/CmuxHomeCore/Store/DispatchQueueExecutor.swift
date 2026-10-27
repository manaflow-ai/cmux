#if !canImport(Darwin)
import Dispatch

/// The `SerialExecutor` conformance Apple's `DispatchSerialQueue` has and corelibs Dispatch (Linux) lacks:
/// every job runs on one serial queue of its own, so an actor on it (``HomeCache``) blocks that queue's
/// thread, never a cooperative pool thread.
final class DispatchQueueExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
#endif
