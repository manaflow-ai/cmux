public import Foundation
import Dispatch

/// Starts and stops long-lived child processes (a stream, a helper) off the caller's thread, in call order.
///
/// `Process.run()` is a fork and exec: hundreds of ms under memory pressure (807 ms seen in STRESS), so a
/// main-actor owner never calls it itself. The owner configures the `Process` (pipes, handlers) and hands it
/// here; the spawn and any later terminate run on one serial queue, so a stop that comes right after a
/// start always reaches the child the start made (never a terminate before the launch, which raises). For
/// a child whose end the caller awaits, use ``AsyncProcess`` instead.
///
/// ```swift
/// let launcher = ProcessLauncher(label: "cmux.now-playing", priority: .userVisible)
/// launcher.launch(stream) { error in Task { @MainActor in self.failed(error) } }
/// launcher.terminate(stream)
/// ```
public final class ProcessLauncher: Sendable {
    private let queue: DispatchQueue

    /// - Parameters:
    ///   - label: the queue's label (it shows in traces).
    ///   - priority: how much a person waits for these children; it sets the queue's and the child's QoS.
    public init(label: String, priority: WorkPriority) {
        queue = DispatchQueue(label: label, qos: priority.qos)
        self.priority = priority
    }

    /// The children's priority.
    private let priority: WorkPriority

    /// Spawns `process` on the queue at the launcher's priority; `failed` runs there when it cannot start.
    public func launch(_ process: Process, failed: @escaping @Sendable (any Error) -> Void = { _ in }) {
        prepare(process)
        queue.async {
            do { try process.run() } catch { failed(error) }
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try process.run()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The child runs at the launcher's priority (never userInteractive).
    private func prepare(_ process: Process) {
        process.qualityOfService = priority.processQoS
    }
}
