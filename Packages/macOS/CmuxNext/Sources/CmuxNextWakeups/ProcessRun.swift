import CmuxNextCompat
import Darwin
import Dispatch
import Foundation

/// One ``AsyncProcess`` run: the child, its pipes' read sources and the continuation that resumes once.
///
/// Every read and the exit drain run on `queue`, so the output is complete and ordered when the exit
/// resolves the run. A stop (timeout, cancel) resolves it first and sends SIGTERM; the later exit only
/// tears the sources down.
final class ProcessRun: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ProcessOutcome, any Error>?
        var resolved = false
        /// A stop that came before ``start(_:)`` had the continuation: start resumes with it and launches nothing.
        var early: Result<ProcessOutcome, any Error>?
        var output = Data()
        var errorOutput = Data()
        var sources: [any DispatchSourceRead] = []
        /// The child's pid from its launch until its exit (0 otherwise), so a stop never signals a reused pid.
        var pid: pid_t = 0
        /// The child has exited (its termination handler ran, which can be before `run()` returns).
        var ended = false
    }

    private let request: ProcessRequest
    private let launch: @Sendable (Process) throws -> Void
    private let queue: DispatchQueue
    // concurrency-allow: one-shot resume guard and buffers shared by the starting task, read sources and the termination callback (lock carve-out).
    private let state = Mutex(State())

    init(_ request: ProcessRequest, launch: @escaping @Sendable (Process) throws -> Void) {
        self.request = request
        self.launch = launch
        queue = DispatchQueue(label: "com.cmuxterm.next.process.\(request.executable.lastPathComponent)",
                              qos: WorkPriority(Task.currentPriority).qos)
    }

    func start(_ continuation: CheckedContinuation<ProcessOutcome, any Error>) {
        let early = state.withLock { state -> Result<ProcessOutcome, any Error>? in
            if state.resolved { return state.early ?? .failure(CancellationError()) }
            state.continuation = continuation
            return nil
        }
        if let early { return continuation.resume(with: early) }
        // The spawn (fork and exec) can take hundreds of ms under memory pressure: it runs on this run's
        // own serial queue (a GCD thread at the caller's QoS), never on the caller's actor (often main)
        // and never on the cooperative pool.
        queue.async { [self] in launchChild() }
    }

    /// Configures and spawns the child, on `queue`. A run stopped before this point spawns nothing.
    private func launchChild() {
        guard !state.withLock({ $0.resolved }) else { return }
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        if let environment = request.environment { process.environment = environment }
        if let directory = request.directory { process.currentDirectoryURL = directory }
        let output = Pipe()
        process.standardOutput = output
        let errorPipe: Pipe? = switch request.errorOutput {
        case .discard: nil
        case .merge: nil
        case .separate: Pipe()
        }
        switch request.errorOutput {
        case .discard: process.standardError = FileHandle.nullDevice
        case .merge: process.standardError = output
        case .separate: process.standardError = errorPipe
        }
        let input = request.input.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errorPipe?.fileHandleForReading.fileDescriptor
        // Active before the launch (no writer has written yet, so no event fires): the exit handler may
        // cancel them at any time after, and an inactive source must never be cancelled and released.
        let sources = [source(outFD, into: \.output)] + (errFD.map { [source($0, into: \.errorOutput)] } ?? [])
        sources.forEach { $0.activate() }
        process.terminationHandler = { [self] ended in
            ended.terminationHandler = nil  // breaks process -> handler -> run
            state.withLock { $0.pid = 0; $0.ended = true }
            let status = ended.terminationStatus, exited = ended.terminationReason == .exit
            queue.async { [self] in
                // Everything the child wrote before it exited is in the pipes now.
                drain(outFD, into: \.output)
                if let errFD { drain(errFD, into: \.errorOutput) }
                let (open, outcome) = state.withLock { state in
                    defer { state.sources = [] }
                    return (state.sources, ProcessOutcome(status: status, exited: exited, output: state.output,
                                                          errorOutput: state.errorOutput))
                }
                open.forEach { $0.cancel() }
                resolve(.success(outcome))
                // The pipes stay open until here: the sources read their descriptors.
                withExtendedLifetime((output, errorPipe, input)) {}
            }
        }
        do {
            try launch(process)
        } catch {
            process.terminationHandler = nil
            sources.forEach { $0.cancel() }
            resolve(.failure(ProcessFailure.launch(error.localizedDescription)))
            return
        }
        let pid = process.processIdentifier
        // Under the lock with the exit's `ended`, so a signal never reaches a pid the child no longer has.
        state.withLock { state in
            guard !state.ended else { return }
            if state.resolved {
                kill(pid, request.stopSignal)
            } else {
                state.pid = pid
            }
        }
        if let input, let bytes = request.input { feed(bytes, to: input) }
    }

    /// Resolves the run with `failure` and sends the child the request's stop signal. A stop before the
    /// launch makes the launch kill the child at once.
    func stop(_ failure: any Error) {
        guard resolve(.failure(failure)) else { return }
        state.withLock { state in
            if state.pid > 0 { kill(state.pid, request.stopSignal) }
        }
    }

    @discardableResult
    private func resolve(_ result: Result<ProcessOutcome, any Error>) -> Bool {
        let (resolved, continuation) = state.withLock { state -> (Bool, CheckedContinuation<ProcessOutcome, any Error>?) in
            guard !state.resolved else { return (false, nil) }
            state.resolved = true
            // Before start: start resumes with it.
            if state.continuation == nil { state.early = result }
            defer { state.continuation = nil }
            return (true, state.continuation)
        }
        continuation?.resume(with: result)
        return resolved
    }

    /// A read source on `fd`, which it makes non-blocking, so the exit drain never blocks on a pipe a
    /// grandchild still holds.
    private func source(_ fd: Int32, into buffer: WritableKeyPath<State, Data> & Sendable) -> any DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            if drain(fd, into: buffer) { source.cancel() }
        }
        state.withLock { $0.sources.append(source) }
        return source
    }

    /// Reads what `fd` holds now without blocking (the descriptor is non-blocking); true at end of file
    /// or on a read error, false when the pipe is empty but still open.
    @discardableResult
    private func drain(_ fd: Int32, into buffer: WritableKeyPath<State, Data> & Sendable) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                state.withLock { $0[keyPath: buffer].append(contentsOf: chunk[0..<count]) }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return false }
            return true
        }
    }

    /// Writes `bytes` to the child's standard input without blocking, then closes it; a child that
    /// exits without reading gets a failed write, not SIGPIPE.
    private func feed(_ bytes: Data, to input: Pipe) {
        let fd = dup(input.fileHandleForWriting.fileDescriptor)
        try? input.fileHandleForWriting.close()
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: data, queue: queue) { done, _, _ in
            if done { channel.close() }
        }
    }
}
