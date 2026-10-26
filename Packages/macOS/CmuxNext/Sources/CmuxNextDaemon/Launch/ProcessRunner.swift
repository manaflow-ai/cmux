public import Foundation
import CmuxNextCompat
import CmuxNextWakeups
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
/// timeout shorter than the work; `timeout` stays the hard cap.
public struct ProcessRunner {
    public init() {}
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        stdin: Data? = nil,
        timeout: Duration,
        progressIdle: Duration? = nil,
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
        let elapsed = Self.stopwatch(clock)
        let progress = progressIdle.map { _ in StdoutProgress(watching: stdoutFile.handle.fileDescriptor, elapsed: elapsed) }
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
                            try box.process.run()
                            if Task.isCancelled { box.kill() }
                        } catch {
                            box.process.terminationHandler = nil
                            continuation.resume(returning: nil)
                        }
                    }
                }
                group.addTask {
                    guard let progressIdle, let progress else {
                        // wakeup-allow: deadline of the child process (timeout), a flexible never-early wait (WakeLeeway)
                        try await clock.sleep(for: timeout, tolerance: WakeLeeway.window(delay: timeout).tolerance)
                        return Int32.min
                    }
                    try await Self.waitForSilence(of: progress, idle: progressIdle, cap: timeout, clock: clock)
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

    /// Returns once `progress` saw no stdout write for `idle`, or at `cap`; throws when cancelled.
    static func waitForSilence(of progress: StdoutProgress, idle: Duration, cap: Duration,
                               clock: any Clock<Duration>) async throws {
        var seen = progress.count
        var waited = Duration.zero
        // wakeup-allow: bounded: the silence deadline re-arms only after stdout progress, until the hard cap
        while waited < cap {
            let window = min(idle, cap - waited)
            // wakeup-allow: deadline of one silence window (no stdout progress in it = timeout)
            try await clock.sleep(for: window, tolerance: WakeLeeway.window(delay: window).tolerance)
            waited += window
            let now = progress.count
            if now == seen { return }
            seen = now
        }
    }

    /// The time on `clock` since this call.
    private static func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let origin = clock.now
        return { origin.duration(to: clock.now) }
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

/// Counts writes to a child's stdout file (`ProcessRunner.run(progressIdle:)`).
/// The watch has its own duplicate of the descriptor, closed by the cancel
/// handler, so the caller may close its file at any time.
final class StdoutProgress: Sendable {
    /// The time since the run started, on the run's clock.
    let elapsed: @Sendable () -> Duration
    private let writes = Mutex<Int>(0)
    private let source = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    private let queue = DispatchQueue(label: "com.cmuxterm.next.process-progress")

    /// No watch: the caller reports each write with ``noteWrite()`` (tests).
    init(elapsed: @escaping @Sendable () -> Duration) {
        self.elapsed = elapsed
    }

    convenience init(watching fd: Int32, elapsed: @escaping @Sendable () -> Duration) {
        self.init(elapsed: elapsed)
        let watched = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard watched >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: watched, eventMask: [.write, .extend],
                                                              queue: queue)
        watch.setEventHandler { [weak self] in self?.noteWrite() }
        watch.setCancelHandler { close(watched) }
        watch.activate()
        source.withLock { $0 = watch }
    }

    /// One write to the child's stdout.
    func noteWrite() { writes.withLock { $0 += 1 } }

    var count: Int { writes.withLock { $0 } }

    func cancel() { source.withLock { $0?.cancel() } }
}
