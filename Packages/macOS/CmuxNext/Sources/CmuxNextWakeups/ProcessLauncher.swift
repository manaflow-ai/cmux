import CmuxNextCompat
import Dispatch
public import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// Starts and stops long-lived child processes (a stream, a helper) off the caller's thread, in call order.
///
/// `Process.run()` is a fork and exec: hundreds of ms under memory pressure (807 ms seen in STRESS), so a
/// main-actor owner never calls it itself. The owner configures the `Process` (pipes, handlers) and hands it
/// here; the spawn and any later terminate run on one serial queue, so a stop that comes right after a
/// start always reaches the child the start made (never a terminate before the launch, which raises). For
/// a child whose end the caller awaits, use ``AsyncProcess`` instead.
///
/// The queue's priority and the child's are separate, as in Chromium: the launcher task runner of
/// content/browser/child_process_launcher_helper.cc is USER_BLOCKING, and
/// `ChildProcessLauncherHelper::SetProcessPriority` sets each child's own priority apart from it.
///
/// ```swift
/// let launcher = ProcessLauncher(label: "cmux.now-playing", priority: .userVisible)
/// launcher.launch(stream) { error in Task { @MainActor in self.failed(error) } }
/// launcher.terminate(stream)
/// ```
public final class ProcessLauncher: Sendable {
    private let queue: DispatchQueue
    /// The children's own priority, for their whole life.
    public let childPriority: WorkPriority
    private let spawn: @Sendable (Process) throws -> Void

    /// - Parameters:
    ///   - label: the queue's label (it shows in traces).
    ///   - priority: how much a person waits for the spawns; it sets the queue's QoS.
    ///   - childPriority: the children's priority for their whole life (`Process.qualityOfService`); nil is
    ///     `priority`. A long-lived child passes its own, so it never competes at the spawn's priority.
    ///   - spawn: starts one child, on the queue; nil is `Process.blockingRun()`, the checked seam that
    ///     reports a spawn on the main thread. A test passes one that records where the spawn ran.
    public init(label: String, priority: WorkPriority, childPriority: WorkPriority? = nil,
                spawn: (@Sendable (Process) throws -> Void)? = nil) {
        queue = DispatchQueue(label: label, qos: priority.qos)
        self.childPriority = childPriority ?? priority
        self.spawn = spawn ?? { try $0.blockingRun() }
    }

    /// Spawns `process` on the queue; `failed` runs there when it cannot start.
    public func launch(_ process: Process, failed: @escaping @Sendable (any Error) -> Void = { _ in }) {
        launch(process, started: {}, failed: failed)
    }

    /// Spawns `process` on the queue; then `started` runs there once the child has its pid, or `failed` when
    /// it cannot start.
    public func launch(_ process: Process, started: @escaping @Sendable () -> Void,
                       failed: @escaping @Sendable (any Error) -> Void) {
        prepare(process)
        queue.async { [spawn] in
            do { try spawn(process) } catch { return failed(error) }
            started()
        }
    }

    /// Sends `process` SIGTERM on the queue, after any launch queued before it; nothing when it is not running.
    public func terminate(_ process: Process) {
        queue.async {
            if process.isRunning { process.terminate() }
        }
    }

    /// Spawns `process` and returns once it started (the caller then may quit: a relaunch helper).
    /// - Throws: the launch error.
    public func launched(_ process: Process) async throws {
        prepare(process)
        try await withOnceThrowingContinuation { [queue, spawn] (continuation: OnceContinuation<Void, any Error>) in
            queue.async {
                do {
                    try spawn(process)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The child runs at the children's priority (never userInteractive).
    private func prepare(_ process: Process) {
        process.qualityOfService = childPriority.processQoS
    }
}
