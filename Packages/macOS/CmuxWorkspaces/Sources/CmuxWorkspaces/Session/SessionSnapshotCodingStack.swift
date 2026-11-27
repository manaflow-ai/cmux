import Foundation

/// Runs session snapshot JSON coding on a stack as large as the main thread's.
///
/// The workspace layout is a recursive pane/split tree, and `JSONEncoder` /
/// `JSONDecoder` recurse a few frames per nesting level. Autosave encodes on a
/// private dispatch queue whose worker threads get a 512 KB stack, which a
/// split tree roughly 150 levels deep overflows (SIGBUS, manaflow-ai/cmux#4656),
/// while the same tree is fine on the 8 MB main thread. Coding on a dedicated
/// thread with a main-sized stack makes persistence no weaker than the rest of
/// the app. Foundation's JSON coders also cap nesting (about 250 splits), and
/// past that they throw, which `save`/`loadOutcome` already treat as a failed
/// save or unusable file. Far deeper trees can still exhaust this stack, as
/// they would on the main thread.
///
/// Public so app-side stores that encode layout snapshots off the main thread
/// (closed-item history) share the same guard.
public struct SessionSnapshotCodingStack: Sendable {
    /// Stack size, in bytes, of the thread that runs off-main coding work.
    public let stackSize: Int

    /// Creates a runner.
    ///
    /// - Parameter stackSize: Stack bytes for the coding thread. Defaults to
    ///   8 MB, the default macOS main-thread stack size.
    public init(stackSize: Int = 8 << 20) {
        self.stackSize = stackSize
    }

    /// Runs `body` synchronously on a thread with ``stackSize`` bytes of stack.
    ///
    /// The main thread already has a large stack, so `body` runs inline there.
    ///
    /// - Parameter body: The coding work to run.
    /// - Returns: The value `body` returns.
    /// - Throws: The error `body` throws.
    public func run<T>(_ body: () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try body()
        }
        return try withoutActuallyEscaping(body) { escapableBody in
            let box = ResultBox(body: escapableBody)
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                box.run()
                done.signal()
            }
            thread.stackSize = stackSize
            thread.qualityOfService = Thread.current.qualityOfService
            thread.start()
            done.wait()
            return try box.result!.get()
        }
    }

    /// Carries the non-Sendable body and its result across the one-shot
    /// thread. The caller blocks on a semaphore until the thread finishes, so
    /// the two threads never touch the box concurrently. `run` drops the body
    /// before signalling, because the `Thread` may outlive the call and
    /// `withoutActuallyEscaping` traps if the body is still referenced.
    private final class ResultBox<T>: @unchecked Sendable {
        private var body: (() throws -> T)?
        private(set) var result: Result<T, any Error>?

        init(body: @escaping () throws -> T) {
            self.body = body
        }

        func run() {
            guard let body else { return }
            self.body = nil
            result = Result { try body() }
        }
    }
}
