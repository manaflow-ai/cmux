internal import Dispatch

/// The private serial queue protects the exit bit for synchronous readers.
final class BackendOnlyRendererWorkerExitFence: @unchecked Sendable {
    private let isolationQueue = DispatchQueue(
        label: "com.cmux.backend-only.renderer-worker-exit-fence"
    )
    private var exited = false

    var hasExited: Bool {
        isolationQueue.sync { exited }
    }

    func finish() {
        isolationQueue.sync {
            exited = true
        }
    }
}
