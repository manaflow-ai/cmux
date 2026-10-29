import CmuxNextCloud
public import Foundation
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
public import CmuxNextWakeups

/// The outcome of one finished ssh (or curl) run.
public struct SSHProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

/// Runs one short process to completion: an ssh with a script on stdin (the
/// probe, the install, the restart) or the Mac-side curl. The spawn runs on a
/// ``ProcessLauncher`` queue, never the caller's actor (Chromium launches on its
/// process launcher task runner, never the UI thread:
/// content/browser/child_process_launcher_helper.cc). Output is read on
/// Foundation's pipe threads (bounded: 1 MiB stdout, 16 KiB stderr tail), never
/// the main actor. The deadline terminates the process; cancelling the calling
/// task does too.
public struct SSHProcessRunner {
    public init() {}
    public enum Input: Sendable {
        case none
        case data(Data)
        case file(URL)
        /// Writes stdin itself through the pipe's descriptor (a secret that must not be copied
        /// into a `Data`, cx-0q7o); the pipe closes after it returns.
        case writer(@Sendable (Int32) -> Void)
    }

    /// `stop` ends the process on the deadline or a cancel (by default SIGTERM to it alone; a caller
    /// whose process leads a group passes one that signals the group). `launcher` spawns it; nil is one
    /// on its own queue at the caller's priority, the child at ``WorkPriority/userVisible`` for its whole
    /// life (an ssh link probe never runs at the priority of the click that started it).
    ///
    /// `@concurrent`: the setup, the stdin write and the waits never run on the caller's actor.
    @concurrent public static func run(_ argv: [String], input: Input = .none, environment: [String: String],
                           deadline: Duration, label: String,
                           stop: @escaping @Sendable (Process) -> Void = { $0.terminate() },
                           launcher: ProcessLauncher? = nil) async throws -> SSHProcessResult {
        guard let executable = argv.first else { throw CocoaError(.executableNotLoadable) }
        let launcher = launcher ?? ProcessLauncher(label: "com.cmuxterm.next.ssh-run", priority: WorkPriority(Task.currentPriority),
                                                   childPriority: .userVisible)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        var inputPipe: Pipe?
        switch input {
        case .none: process.standardInput = FileHandle.nullDevice
        case .file(let url): process.standardInput = try FileHandle(forReadingFrom: url)
        case .data, .writer:
            let pipe = Pipe()
            inputPipe = pipe
            process.standardInput = pipe
        }
        let output = Mutex(Output())
        let stdoutEnded = ExitLatch()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            switch handle.readReady() {
            case .bytes(let data): output.withLock { if $0.stdout.count < 1 << 20 { $0.stdout.append(data) } }
            case .retry: return
            case .end:
                handle.readabilityHandler = nil
                stdoutEnded.finish(0)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: readabilityHandler runs on Foundation's pipe queue, never main; data is ready.
            switch handle.readReady() {
            case .bytes(let data):
                output.withLock { state in
                    state.stderr.append(data)
                    if state.stderr.count > 16 * 1024 { state.stderr.removeFirst(state.stderr.count - 16 * 1024) }
                }
            case .retry: return
            case .end: handle.readabilityHandler = nil
            }
        }
        let exit = ExitLatch()
        process.terminationHandler = { exit.finish($0.terminationStatus) }
        // The cancel and deadline handlers below are installed once the child runs.
        try await launcher.launched(process)
        if case .data(let data) = input, let inputPipe {
            let writer = inputPipe.fileHandleForWriting
            // Scripts are a few KiB, well under the pipe buffer.
            try? writer.write(contentsOf: data)
            try? writer.close()
        }
        if case .writer(let write) = input, let inputPipe {
            let writer = inputPipe.fileHandleForWriting
            write(writer.fileDescriptor)
            try? writer.close()
        }
        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                // withDeadline waits for its operation after the deadline cancels it, and the
                // exit only comes once the process is stopped: terminate it on that cancel.
                try await withDeadline(deadline, label: label) {
                    await withTaskCancellationHandler { await exit.awaitValue() } onCancel: { stop(process) }
                }
            } onCancel: {
                stop(process)
            }
        } catch {
            if process.isRunning { stop(process) }
            throw error
        }
        // Output can trail the exit; wait briefly for stdout's end. A
        // ControlPersist master may keep the pipe open, so never wait for it
        // unbounded.
        _ = try? await withDeadline(.milliseconds(500), label: label + " output") { await stdoutEnded.awaitValue() }
        let drained = output.withLock { $0 }
        return SSHProcessResult(status: status, stdout: String(decoding: drained.stdout, as: UTF8.self),
                                stderr: String(decoding: drained.stderr, as: UTF8.self))
    }

    private struct Output {
        var stdout = Data()
        var stderr = Data()
    }
}

/// One process exit, awaited once or many times.
final class ExitLatch: Sendable {
    private struct State {
        var status: Int32?
        var waiters: [OnceContinuation<Int32, OnceContinuationError>] = []
    }

    private let state = Mutex(State())

    func finish(_ status: Int32) {
        let waiters = state.withLock { state -> [OnceContinuation<Int32, OnceContinuationError>] in
            state.status = status
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    /// The exit status; -1 ("status unknown") when the wait was dropped without one.
    func awaitValue() async -> Int32 {
        (try? await withOnceContinuation { (waiter: OnceContinuation<Int32, OnceContinuationError>) in
            let done = state.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.waiters.append(waiter)
                return nil
            }
            if let done { waiter.resume(returning: done) }
        }) ?? -1
    }
}
