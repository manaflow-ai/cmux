public import Dispatch

/// Starts child processes off the main thread and off Swift's cooperative pool, in call order, at the
/// children's QoS: Chrome's process launcher task runner (content/browser/child_process_launcher_helper.cc,
/// `GetProcessLauncherTaskRunner`: a dedicated thread with `MayBlock`), where every child is spawned.
///
/// Each item runs on a named serial queue (the blocking detector's ``BlockingContext/dedicated``) as an
/// enforced-QoS work item at the queue's ``ChildProcessQoS``, so the spawning thread is never the caller's
/// thread and never runs above the child's class: a child spawned from here cannot start at the
/// main thread's `.userInteractive`. Pass the same QoS to ``blockingPosixSpawn(_:_:_:_:_:_:qos:fileID:line:)``
/// inside the item, which also clamps utility and background children.
///
/// Owners make their own queue (one per launcher, or one per spawn for a static launcher); there is no
/// shared one.
///
/// ```swift
/// let spawns = ChildSpawnQueue(label: "com.cmuxterm.app.next.crash-watcher.spawn", qos: .utility)
/// let pid = try await spawns.run { () throws(SpawnError) -> pid_t in try spawnWatcher() }
/// ```
public final class ChildSpawnQueue: Sendable {
    private let queue: DispatchQueue
    /// The QoS of every item and of the children they spawn.
    public let qos: ChildProcessQoS

    /// - Parameters:
    ///   - label: The queue's label (traces and threading-model.md name it).
    ///   - qos: The children's QoS; the queue and each item run at it.
    public init(label: String, qos: ChildProcessQoS) {
        queue = DispatchQueue(label: label, qos: qos.dispatchQoS)
        self.qos = qos
    }

    /// Runs `body` (the spawn) on the queue and returns its result; the caller's thread does not wait.
    ///
    /// - Throws: What `body` throws.
    public func run<T: Sendable, Failure: Error>(_ body: @escaping @Sendable () throws(Failure) -> T) async throws(Failure) -> T {
        let item = qos.dispatchQoS
        let queue = queue
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Failure>, Never>) in
            queue.async(execute: DispatchWorkItem(qos: item, flags: .enforceQoS) {
                do throws(Failure) {
                    continuation.resume(returning: .success(try body()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            })
        }
        return try outcome.get()
    }

    /// Queues `body` (a spawn nobody awaits, such as a watcher started at launch) and returns at once.
    public func post(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: DispatchWorkItem(qos: qos.dispatchQoS, flags: .enforceQoS, block: body))
    }
}
