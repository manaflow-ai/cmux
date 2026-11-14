import CmuxNextCloud
public import Foundation
import CmuxNextCompat

/// The outcome of one finished ssh (or curl) run.
public struct SSHProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    /// The last line of `stderr` (what a failed remote command said last), or nil when it is empty.
    public var lastStderrLine: String? {
        stderr.split(separator: "\n").last.map(String.init)
    }
}

/// Runs one short process to completion: an ssh with a script on stdin (the
/// probe, the install, the restart) or the Mac-side curl. Output is read on
/// Foundation's pipe threads (bounded: 1 MiB stdout, 16 KiB stderr tail),
/// never the main actor. The deadline terminates the process; cancelling
/// the calling task does too. Both output pipes close when the run returns
/// or throws.
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
    /// whose process leads a group passes one that signals the group).
    /// `@concurrent`: a main-actor caller's launch and stdin never run on the main thread.
    @concurrent public static func run(_ argv: [String], input: Input = .none, environment: [String: String],
                           deadline: Duration, label: String,
                           stop: @escaping @Sendable (Process) -> Void = { $0.terminate() }) async throws -> SSHProcessResult {
        guard let executable = argv.first else { throw CocoaError(.executableNotLoadable) }
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
        if let inputPipe {
            // A remote command can close stdin while the caller is still writing. Handle EPIPE
            // in the writer instead of allowing SIGPIPE to terminate the app.
            _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
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
        // On every way out (the exit, the deadline, a cancel, a launch that failed) both readers stop
        // and both read ends close. End of file alone does not do it: a process the command left
        // behind with the pipes open (a ControlPersist master) never ends them, and each run would
        // keep two pipes and two readers for as long as that process lives.
        defer {
            for reader in [stdout.fileHandleForReading, stderr.fileHandleForReading] {
                reader.readabilityHandler = nil
                try? reader.close()
            }
        }
        let exit = ExitLatch()
        process.terminationHandler = { exit.finish($0.terminationStatus) }
        try process.run()
        // Stdin goes on the feed's own queue, never this task: even a few KiB can wait in `write`
        // (a child that never reads, the kernel's pipe memory used up), and that wait would hold
        // off the deadline below. The deadline's stop ends the child, which ends a waiting write.
        if let inputPipe {
            let feed = PipeFeed(inputPipe.fileHandleForWriting)
            if case .data(let data) = input { feed.write(data) }
            if case .writer(let write) = input { feed.write(with: write) }
            feed.close()
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
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }

    private let state = Mutex(State())

    func finish(_ status: Int32) {
        let waiters = state.withLock { state -> [CheckedContinuation<Int32, Never>] in
            state.status = status
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
    }

    func awaitValue() async -> Int32 {
        await withCheckedContinuation { waiter in
            let done = state.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.waiters.append(waiter)
                return nil
            }
            if let done { waiter.resume(returning: done) }
        }
    }
}
