public import Dispatch
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Starts child processes off the main thread and off Swift's cooperative pool, in call order: Chrome's
/// process launcher (content/browser/child_process_launcher_helper.cc, `GetProcessLauncherTaskRunner`: one
/// sequence with `MayBlock` where children are spawned).
///
/// One serial queue per owner, made once with the owner (a Chromium host launcher, a pane's shell, the
/// acpmux host), never per spawn. Chrome's sequence is process-wide; cmux has no process-wide instance to
/// share without a singleton, so each long-lived owner keeps its own, as CmuxNextWakeups' `ProcessLauncher`
/// does. Every label is `com.cmuxterm.next.child-launcher.<owner>`. An item
/// only spawns (and sets up the child's descriptors), never waits for the child, so it holds its queue for
/// one `posix_spawn`.
///
/// ``priority`` is the one priority model's (``MayBlockPriority``, CmuxNextWakeups' `WorkPriority`): it sets
/// the QoS of the spawning thread, which is how fast the spawn itself runs. It does not set the child's QoS:
/// pass it to ``blockingPosixSpawn(_:_:_:_:_:_:priority:fileID:line:)``, which clamps a best-effort or idle
/// child. A higher class for a cmux child is the child's own task role (task 235, `ProcessRole`; Chrome's
/// `SetCurrentTaskDefaultRole`, base/process/launch_mac.cc).
///
/// ```swift
/// let launcher = ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.crash-watcher", priority: .bestEffort)
/// let pid = try await launcher.run { (permit) throws(SpawnError) -> pid_t in try spawnWatcher(launcher.priority, permit) }
/// ```
public final class ChildProcessLauncher: Sendable {
    /// The priority of every spawn this launcher runs, and of the children it clamps.
    public let priority: MayBlockPriority
    private let queue: DispatchQueue

    /// - Parameters:
    ///   - label: The queue's label (traces show it; plans/cmux-next/threading-model.md lists it).
    ///   - priority: How much a person waits for these children.
    public init(label: String, priority: MayBlockPriority) {
        self.priority = priority
        queue = DispatchQueue(label: label, qos: priority.qos)
    }

    /// Runs `body` (the spawn) on the launcher's queue and returns its result; the caller's thread does not wait.
    ///
    /// - Throws: What `body` throws.
    public func run<T: Sendable, Failure: Error>(_ body: @escaping @Sendable () throws(Failure) -> T) async throws(Failure) -> T {
        let (queue, qos) = (queue, priority.qos)
        let outcome = try? await withOnceContinuation { (continuation: OnceContinuation<Result<T, Failure>, OnceContinuationError>) in
            queue.async(execute: DispatchWorkItem(qos: qos, flags: .enforceQoS) {
                do throws(Failure) {
                    continuation.resume(returning: .success(try body()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            })
        }
        // An abandoned continuation means the work item was dropped before it ran, so the spawn never
        // happened: queue it again.
        guard let outcome else { return try await run(body) }
        return try outcome.get()
    }

    /// Queues `body` (a spawn nobody awaits, such as a watcher started at launch) and returns at once.
    public func post(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: DispatchWorkItem(qos: priority.qos, flags: .enforceQoS, block: body))
    }

    /// ``run(_:)`` whose body gets the launcher's ``BlockingPermit`` (issuer ``BlockingPermit/Issuer/dedicated``)
    /// for the seams it calls (``blockingPosixSpawn(_:_:_:_:_:_:priority:_:fileID:line:)``).
    ///
    /// - Throws: What `body` throws.
    public func run<T: Sendable, Failure: Error>(
        _ body: @escaping @Sendable (borrowing BlockingPermit) throws(Failure) -> T
    ) async throws(Failure) -> T {
        try await run { () throws(Failure) -> T in try body(BlockingPermit(issuer: .dedicated)) }
    }

    /// ``post(_:)`` whose body gets the launcher's ``BlockingPermit``.
    public func post(_ body: @escaping @Sendable (borrowing BlockingPermit) -> Void) {
        post { () -> Void in body(BlockingPermit(issuer: .dedicated)) }
    }
}
