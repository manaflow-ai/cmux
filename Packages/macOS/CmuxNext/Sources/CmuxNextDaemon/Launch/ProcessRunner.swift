public import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
}

/// Runs a child process off the main actor with a deadline on an injected
/// clock. Output goes to unlinked temp files rather than pipes: a chatty
/// child cannot fill a pipe and deadlock, and a grandchild that keeps the
/// descriptor (an agent started from a shell rc file) cannot hold an EOF wait
/// open forever.
public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration,
        clock: any Clock<Duration>
    ) async throws -> ProcessResult {
        let stdoutFile = try TempOutput()
        let stderrFile = try TempOutput()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutFile.handle
        process.standardError = stderrFile.handle

        let box = ProcessBox(process)
        // A cancelled caller kills the child, so the waiter below ends now
        // instead of at the child's own exit or the deadline.
        let status: Int32 = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32?.self) { group in
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                        box.process.terminationHandler = { process in
                            continuation.resume(returning: process.terminationStatus)
                        }
                        do {
                            try box.process.run()
                            if Task.isCancelled { box.kill() }
                        } catch {
                            box.process.terminationHandler = nil
                            continuation.resume(returning: nil)
                        }
                    }
                }
                group.addTask {
                    // wakeup-allow: one-shot deadline (child process timeout)
                    try await clock.sleep(for: timeout)
                    return Int32.min
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { return Int32.min }
                guard let status = first else {
                    throw DaemonError.launchFailed("could not start \(executable.path)")
                }
                if status == Int32.min {
                    // Interactive shells ignore SIGTERM, so kill outright; the
                    // waiter task resumes once the child is reaped.
                    kill(box.process.processIdentifier, SIGKILL)
                    throw DaemonError.timedOut("\(executable.lastPathComponent) \(arguments.joined(separator: " "))")
                }
                return status
            }
        } onCancel: {
            box.kill()
        }
        return ProcessResult(status: status, stdout: stdoutFile.contents(), stderr: stderrFile.contents())
    }
}

/// `Process` is not Sendable; it is only touched from the group tasks above.
final class ProcessBox: @unchecked Sendable {
    let process: Process
    private let signal: @Sendable (pid_t, Int32) -> Void

    init(_ process: Process, signal: @escaping @Sendable (pid_t, Int32) -> Void = { _ = Darwin.kill($0, $1) }) {
        self.process = process
        self.signal = signal
    }

    /// SIGKILL to this child only; never before launch (pid 0 would be our group).
    func kill() {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        signal(pid, SIGKILL)
    }
}
