public import Foundation
import CmuxNextCompat
import Darwin
import Dispatch

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
///
/// `progressIdle`: the child also fails when its stdout stays silent that
/// long. A child that reports progress on stdout (`server ensure --restore-progress`
/// while the owner restores) is bounded by its own progress, not by a fixed
/// timeout shorter than the work. `timeout` stays the hard cap when supplied; nil selects an
/// idle-only deadline and requires `progressIdle`. Existing callers retain their elapsed deadlines.
public struct ProcessRunner {
    public init() {}
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        stdin: Data? = nil,
        timeout: Duration?,
        progressIdle: Duration? = nil,
        // Opt-in diagnostic/reply retention, independent of the child's upload/file size. Both
        // streams are bounded; nil preserves the complete-output contract for existing callers.
        outputTailBytes: Int? = nil,
        clock: any Clock<Duration>
    ) async throws -> ProcessResult {
        guard timeout != nil || progressIdle != nil else { throw DaemonError.launchFailed("process requires an elapsed or idle deadline") }
        if let outputTailBytes, outputTailBytes <= 0 { throw DaemonError.launchFailed("output tail must be positive") }
        // A caller cancelled before the child starts gets no child (its `onCancel` runs at once,
        // before anything launched).
        try Task.checkCancellation()
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
            // Close-on-exec on both ends: no other child this app starts
            // inherits a readable copy (Process dup2s the read end into the
            // child's stdin, which clears the flag there only).
            _ = fcntl(input.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
            process.standardInput = input
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        defer { try? input?.fileHandleForReading.close() }
        process.standardOutput = stdoutFile.handle
        process.standardError = stderrFile.handle
        // Each stdout write is a progress event (a vnode event on the temp
        // file; the child's writes land on the same file).
        let progress = progressIdle.map { _ in StdoutProgress(watching: stdoutFile.handle.fileDescriptor) }
        defer { progress?.cancel() }

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
                            // Launch and cancel exclude each other: a cancel that lands first means no child.
                            guard try box.launch() else {
                                box.process.terminationHandler = nil
                                continuation.resume(returning: nil)
                                return
                            }
                            if Task.isCancelled { box.kill() }
                        } catch {
                            box.process.terminationHandler = nil
                            continuation.resume(returning: nil)
                        }
                    }
                }
                group.addTask {
                    try await waitForDeadline(timeout: timeout, progressIdle: progressIdle, clock: clock,
                                              progress: progress.map { counter in { @Sendable in counter.count } })
                    return Int32.min
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { return Int32.min }
                guard let status = first else {
                    try Task.checkCancellation()
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
            box.cancel()
        }
        return ProcessResult(status: status, stdout: stdoutFile.contents(tailBytes: outputTailBytes), stderr: stderrFile.contents(tailBytes: outputTailBytes))
    }

    /// The production watchdog, shared with deterministic clock/progress regressions. Returning
    /// means the caller must stop/reap its child; cancellation removes the pending clock sleep.
    static func waitForDeadline(timeout: Duration?, progressIdle: Duration?, clock: any Clock<Duration>,
                                progress: (@Sendable () -> Int)?) async throws {
        guard let progressIdle, let progress else {
            guard let timeout else { throw DaemonError.launchFailed("process requires an elapsed or idle deadline") }
            // wakeup-allow: one-shot deadline, cancelled when the child exits or its caller cancels.
            try await clock.sleep(for: timeout)
            return
        }
        var seen = progress()
        var waited = Duration.zero
        while timeout.map({ waited < $0 }) ?? true {
            let window = timeout.map { min(progressIdle, $0 - waited) } ?? progressIdle
            // wakeup-allow: one idle window, stopped on child exit/cancel; progress permits the next window.
            try await clock.sleep(for: window)
            waited += window
            let now = progress()
            if now == seen { return }
            seen = now
        }
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

    /// Set under the lock by `cancel()`; `launch()` reads it under the same lock.
    private let cancelled = Mutex<Bool>(false)

    /// Starts the child unless `cancel()` already ran; false when it did (the child never starts).
    func launch() throws -> Bool {
        try cancelled.withLock { cancelled in
            if cancelled { return false }
            try process.run()
            return true
        }
    }

    /// A cancelled caller: no child starts after this, and one that already started is killed.
    func cancel() {
        cancelled.withLock { cancelled in
            cancelled = true
            kill()
        }
    }

    /// SIGKILL to this child only, and only while it runs: never before launch
    /// (`processIdentifier` of a process that has not launched raises, and a pid of 0
    /// would be our own process group) and never after exit (the pid may belong to
    /// another process by then).
    func kill() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        signal(pid, SIGKILL)
    }
}

/// Counts writes to a child's stdout file (`ProcessRunner.run(progressIdle:)`).
/// The watch has its own duplicate of the descriptor, closed by the cancel
/// handler, so the caller may close its file at any time.
final class StdoutProgress: Sendable {
    private let writes = Mutex<Int>(0)
    private let source = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    private let queue = DispatchQueue(label: "com.cmuxterm.next.process-progress")

    init(watching fd: Int32) {
        let watched = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard watched >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watched, eventMask: [.write, .extend],
                                                              queue: queue)
        watch.setEventHandler { [weak self] in self?.writes.withLock { $0 += 1 } }
        watch.setCancelHandler { close(watched) }
        watch.activate()
        source.withLock { $0 = watch }
    }

    var count: Int { writes.withLock { $0 } }

    func cancel() { source.withLock { $0?.cancel() } }
}
