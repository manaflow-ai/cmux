import CmuxNextCompat
public import Foundation
import Dispatch

extension AsyncProcess {
    /// Spawns a child the caller configured itself (its own pipes or output files, its own termination
    /// handler) and returns once it started.
    ///
    /// For a caller that reads the child's output as it comes or awaits its end in its own way (a search that
    /// stops at a match limit, a run whose output goes to files); ``run(_:)`` covers every other awaited child.
    /// The spawn (a fork and exec, hundreds of ms under memory pressure: 807 ms in STRESS) runs on a serial
    /// queue of its own at the caller's QoS, as ``run(_:)``'s does: never on the caller's actor and never on a
    /// cooperative pool thread. The child runs at the caller's priority.
    ///
    /// ```swift
    /// process.terminationHandler = { exit.resolve($0.terminationStatus) }
    /// try await AsyncProcess.spawn(process)
    /// for try await byte in output.fileHandleForReading.bytes { ... }
    /// ```
    ///
    /// - Throws: the error `Process.run()` throws when the child cannot start.
    public static func spawn(_ process: Process) async throws {
        let priority = WorkPriority(Task.currentPriority)
        process.qualityOfService = priority.processQoS
        let name = process.executableURL?.lastPathComponent ?? "child"
        let queue = DispatchQueue(label: "com.cmuxterm.next.process.spawn.\(name)", qos: priority.qos)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try process.blockingRun()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
