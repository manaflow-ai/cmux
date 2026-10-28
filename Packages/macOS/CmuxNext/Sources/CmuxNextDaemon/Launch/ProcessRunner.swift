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
            try input.fileHandleForWriting.blockingWrite(contentsOf: stdin)
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
        // The spawn runs on the launcher's queue, never the caller's actor or the cooperative pool, and the
        // child at the caller's priority's processQoS (Chromium's launcher thread,
        // content/browser/child_process_launcher_helper.cc).
        let launcher = ProcessLauncher(label: "com.cmuxterm.next.daemon.process", priority: WorkPriority(Task.currentPriority))
        // A cancelled caller kills the child, so the waiter below ends now
        // instead of at the child's own exit or the deadline.
        let status: Int32 = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32?.self) { group in
                group.addTask {
                    // Set before the launch: a child that exits at once still reports its status.
                    let exit = FirstOutcome<Int32>()
                    box.process.terminationHandler = { process in exit.resolve(process.terminationStatus) }
                    do {
                        try await launcher.launched(box.process)
                    } catch {
                        box.process.terminationHandler = nil
                        return nil
                    }
                    // A cancel or timeout during the launch found no child to kill: this kill reaches it.
                    if Task.isCancelled { box.kill() }
                    return await exit.value()
                }
                group.addTask {
                    guard let progressIdle, let progress else {
                        // wakeup-allow: deadline of the child process (timeout), a flexible never-early wait (WakeLeeway)
                        // timer-class-allow: a race timeout in the run's task group (the child's exit wins it); it schedules no main-thread job
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

    /// Returns once `progress` saw no stdout write for `idle` (from the run's start or its last write), or at
    /// `cap`; throws when cancelled.
    ///
    /// One deadline, moved lazily as Chromium's `DelayTimerBase` does (base/timer/timer.cc): a write only records
    /// its time, and a fire before the desired time sleeps on for the time left to it.
    static func waitForSilence(of progress: StdoutProgress, idle: Duration, cap: Duration,
                               clock: any Clock<Duration>) async throws {
        // wakeup-allow: deadline: one silence deadline; a pass ends at it or sleeps on for the time a write added
        while true {
            let now = progress.elapsed()
            let end = min((progress.lastWrite ?? .zero) + idle, cap)
            guard end > now else { return }
            let left = end - now
            // wakeup-allow: deadline: to the silence deadline; another pass only when a write moved it
            // timer-class-allow: a race timeout in the run's task group (the child's exit wins it); it schedules no main-thread job
            try await clock.sleep(for: left, tolerance: WakeLeeway.window(delay: left).tolerance)
        }
    }

    /// The time on `clock` since this call.
    private static func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }
}

/// The child of one ``ProcessRunner/run(executable:arguments:environment:stdin:timeout:progressIdle:clock:)``,
/// shared by its waiter task, its deadline task and the cancellation handler (`Process` is Sendable).
final class ProcessBox: Sendable {
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
