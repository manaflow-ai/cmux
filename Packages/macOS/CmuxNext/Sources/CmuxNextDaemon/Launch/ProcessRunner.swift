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
        stdin: Data? = nil,
        timeout: Duration,
        clock: any Clock<Duration>
    ) async throws -> ProcessResult {
        let stdoutFile = try TempOutput()
        let stderrFile = try TempOutput()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        // `stdin` (the install key) goes through a pipe, never argv or env.
        // It is far below the pipe buffer, so it is written before launch
        // and the write end closes: the child reads it to end of file.
        let input = stdin.map { _ in Pipe() }
        if let input, let stdin {
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
            process.standardInput = input
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        defer { try? input?.fileHandleForReading.close() }
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
                    box.kill()
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
    /// Sends a signal (tests record it instead).
    private let signal: @Sendable (pid_t, Int32) -> Void

    init(_ process: Process, signal: @escaping @Sendable (pid_t, Int32) -> Void = { _ = Darwin.kill($0, $1) }) {
        self.process = process
        self.signal = signal
    }

    /// SIGKILL to this child only, and only while it runs: never before launch
    /// (pid 0 would be our own process group) and never after exit (the pid
    /// may belong to another process by then).
    func kill() {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        signal(pid, SIGKILL)
    }
}
