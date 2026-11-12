import Dispatch

/// Observes the real writer task at suspension boundaries, never on a timer.
@available(macOS 15.0, *)
final class SocketWriterTestExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "cmux.tests.socket-writer-executor")
    private let didRunJob: @Sendable () -> Void

    deinit {}

    init(didRunJob: @escaping @Sendable () -> Void) {
        self.didRunJob = didRunJob
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { [self] in
            job.runSynchronously(on: asUnownedTaskExecutor())
            didRunJob()
        }
    }
}
