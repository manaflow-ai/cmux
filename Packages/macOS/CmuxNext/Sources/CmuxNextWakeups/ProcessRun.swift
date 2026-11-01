import CmuxNextCompat
import Darwin
import Dispatch
import Foundation

/// One ``AsyncProcess`` run: the child, its pipes' read sources and the continuation that resumes once.
///
/// Every read and the exit drain run on `queue`, so the output is complete and ordered when the exit
/// resolves the run. A stop (timeout, cancel) sends the request's stop signal and, when the child is
/// still running after the request's kill grace, SIGKILL; the exit cancels that deadline. A
/// ``ProcessRequest/CancelBehavior/stop`` run resolves at the stop; a
/// ``ProcessRequest/CancelBehavior/finish`` run resolves at the child's exit or at the SIGKILL, whichever
/// is first. Output that arrives after the run resolved is read (so the child never blocks on a full
/// pipe while it cleans up) and dropped.
final class ProcessRun: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ProcessOutcome, any Error>?
        var resolved = false
        /// A stop that came before ``start(_:)`` had the continuation: start resumes with it and launches nothing.
        var early: Result<ProcessOutcome, any Error>?
        var output = Data()
        var errorOutput = Data()
        var sources: [any DispatchSourceRead] = []
        var processSource: (any DispatchSourceProcess)?
        var exitHandled = false
        /// The child's pid from its launch until its termination handler runs (0 otherwise). Foundation's
        /// Process reaps the child just before it calls that handler, so a signal sent in that short window
        /// could reach a pid the kernel has handed to a new process; the kernel hands pids out in order, so
        /// that needs the whole pid space to wrap within the window.
        var pid: pid_t = 0
        /// The dedicated process group, when this request uses group termination. It remains valid after the
        /// leader exits so the grace-period SIGKILL can still stop hooks and filters it started.
        var processGroup: pid_t = 0
        /// The child has exited (its termination handler ran, which can be before `run()` returns).
        var ended = false
        /// The failure of the first stop (timeout, cancel). A stop before the launch makes the launch
        /// signal the child at once; a ``ProcessRequest/CancelBehavior/finish`` run resolves with it at the exit.
        var stop: (any Error)?
    }

    private let request: ProcessRequest
    /// The caller's priority: the read queue's QoS and the child's own.
    private let priority: WorkPriority
    private let queue: DispatchQueue
    // concurrency-allow: one-shot resume guard and buffers shared by the starting task, read sources and the termination callback (lock carve-out).
    private let state = Mutex(State())
    /// SIGKILL for a stopped child still running after the request's kill grace.
    private let killDeadline: DemandTimer

    init(_ request: ProcessRequest, clock: any Clock<Duration>) {
        self.request = request
        let name = request.executable.lastPathComponent
        priority = WorkPriority(Task.currentPriority)
        queue = DispatchQueue(label: "com.cmuxterm.next.process.\(name)", qos: priority.qos)
        killDeadline = DemandTimer(owner: "process.kill.\(name)", clock: clock)
    }

    func start(_ continuation: CheckedContinuation<ProcessOutcome, any Error>) {
        let early = state.withLock { state -> Result<ProcessOutcome, any Error>? in
            if state.resolved { return state.early ?? .failure(CancellationError()) }
            state.continuation = continuation
            return nil
        }
        if let early {
            killDeadline.cancel()  // nothing launches
            return continuation.resume(with: early)
        }
        // The spawn (fork and exec, hundreds of ms under memory pressure: 807 ms in STRESS) runs on this
        // run's own serial queue, a GCD thread at the caller's QoS: never on the caller's actor (often
        // main) and never on the cooperative pool.
        queue.async { [self] in launchChild() }
    }

    /// Configures and spawns the child, on `queue`. A run stopped before this point spawns nothing.
    private func launchChild() {
        guard !state.withLock({ $0.resolved || $0.stop != nil }) else {
            killDeadline.cancel()
            // A finish-run stopped before its launch has no exit to wait for: it resolves with its stop.
            if let stop = state.withLock({ $0.stop }) { resolve(.failure(stop)) }
            return
        }
        if request.terminationScope == .processGroup {
            launchProcessGroupChild()
            return
        }
        let process = Process()
        // The child runs at its waiter's priority (a best-effort poll never competes at .default; a git run
        // a person waits for gets userInitiated).
        process.qualityOfService = priority.processQoS
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
        var sources = [source(outFD, of: output, into: \.output)]
        if let errorPipe, let errFD { sources.append(source(errFD, of: errorPipe, into: \.errorOutput)) }
        sources.forEach { $0.activate() }
        process.terminationHandler = { [self] ended in
            ended.terminationHandler = nil  // breaks process -> handler -> run
            state.withLock { $0.pid = 0; $0.ended = true }
            killDeadline.cancel()
            let status = ended.terminationStatus, exited = ended.terminationReason == .exit
            queue.async { [self] in
                // Everything the child wrote before it exited is in the pipes now.
                drain(outFD, into: \.output)
                if let errFD { drain(errFD, into: \.errorOutput) }
                let (open, result) = state.withLock { state -> ([any DispatchSourceRead], Result<ProcessOutcome, any Error>) in
                    defer { state.sources = [] }
                    if let stop = state.stop { return (state.sources, .failure(stop)) }
                    return (state.sources, .success(ProcessOutcome(status: status, exited: exited, output: state.output,
                                                                   errorOutput: state.errorOutput)))
                }
                open.forEach { $0.cancel() }
                resolve(result)
                // The pipes stay open until here: the drains above read their descriptors. Each source's
                // cancel handler keeps its pipe until that source's (asynchronous) cancel has finished.
                withExtendedLifetime((output, errorPipe, input)) {}
            }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            sources.forEach { $0.cancel() }
            killDeadline.cancel()
            resolve(.failure(ProcessFailure.launch(error.localizedDescription)))
            return
        }
        let pid = process.processIdentifier
        // Under the lock with the exit's `ended`, so a signal never reaches a pid the child no longer has.
        let stopped = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.pid = pid
            return state.stop != nil
        }
        if stopped { send(request.stopSignal) }
        request.onLaunch?(pid)
        if let input, let bytes = request.input { feed(bytes, to: input) }
    }

    /// Foundation's `Process` does not expose `posix_spawn` attributes, so group-scoped runs use a
    /// direct spawn with `POSIX_SPAWN_SETPGROUP`. The group is created before the executable runs, which
    /// closes the race where a git hook could fork before a later `setpgid` call.
    private func launchProcessGroupChild() {
        let output = Pipe()
        let errorPipe: Pipe? = switch request.errorOutput {
        case .discard, .merge: nil
        case .separate: Pipe()
        }
        let input = request.input.map { _ in Pipe() }
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errorPipe?.fileHandleForReading.fileDescriptor
        var sources = [source(outFD, of: output, into: \.output)]
        if let errorPipe, let errFD { sources.append(source(errFD, of: errorPipe, into: \.errorOutput)) }
        sources.forEach { $0.activate() }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            sources.forEach { $0.cancel() }
            resolve(.failure(ProcessFailure.launch("could not configure process group")))
            return
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            sources.forEach { $0.cancel() }
            resolve(.failure(ProcessFailure.launch("could not configure process group")))
            return
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let stderrConfigured: Int32
        switch request.errorOutput {
        case .discard:
            stderrConfigured = "/dev/null".withCString { posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, $0, O_WRONLY, 0) }
        case .merge:
            stderrConfigured = posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        case .separate:
            // .separate always creates errorPipe above; a missing pipe fails the configured guard below.
            stderrConfigured = errorPipe.map {
                posix_spawn_file_actions_adddup2(&actions, $0.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
            } ?? EBADF
        }
        let stdinConfigured: Int32
        if let input {
            stdinConfigured = posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        } else {
            stdinConfigured = "/dev/null".withCString { posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDONLY, 0) }
        }
        let configured = posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0
            && stderrConfigured == 0
            && stdinConfigured == 0
            && (request.directory?.path.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) } ?? 0) == 0
            && posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
        guard configured else {
            sources.forEach { $0.cancel() }
            resolve(.failure(ProcessFailure.launch("could not configure process group")))
            return
        }

        let argv = [request.executable.path] + request.arguments
        let environment = request.environment?.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawned = withCStrings(argv) { argv in
            if let environment {
                return withCStrings(environment) { envp in
                    posix_spawn(&pid, request.executable.path, &actions, &attributes, argv, envp)
                }
            }
            return posix_spawn(&pid, request.executable.path, &actions, &attributes, argv, environ)
        }
        guard spawned == 0 else {
            sources.forEach { $0.cancel() }
            resolve(.failure(ProcessFailure.launch(String(cString: strerror(spawned)))))
            return
        }
        let childPID = pid
        try? output.fileHandleForWriting.close()
        try? errorPipe?.fileHandleForWriting.close()
        try? input?.fileHandleForReading.close()

        let stopped = state.withLock { state -> Bool in
            guard !state.ended else { return false }
            state.pid = childPID
            state.processGroup = childPID
            return state.stop != nil
        }
        if stopped { send(request.stopSignal) }
        let finishExit: @Sendable (Int32?) -> Void = { [self] providedStatus in
            let first = state.withLock { state -> Bool in
                guard !state.exitHandled else { return false }
                state.exitHandled = true
                return true
            }
            guard first else { return }
            var rawStatus = providedStatus ?? 0
            if providedStatus == nil {
                repeat { _ = waitpid(childPID, &rawStatus, 0) } while errno == EINTR
            }
            state.withLock { state in
                state.pid = 0
                state.ended = true
            }
            let exited = (rawStatus & 0x7f) == 0
            let status = exited ? (rawStatus >> 8) & 0xff : rawStatus & 0x7f
            let source = state.withLock { state -> (any DispatchSourceProcess)? in
                defer { state.processSource = nil }
                return state.processSource
            }
            source?.cancel()
            let stopped = state.withLock { $0.stop != nil }
            let stop = state.withLock { $0.stop }
            if !stopped { killDeadline.cancel() }
            queue.async { [self] in
                drain(outFD, into: \.output)
                if let errFD { drain(errFD, into: \.errorOutput) }
                if stopped {
                    let open = state.withLock { state -> [any DispatchSourceRead] in
                        let open = state.sources
                        state.sources = []
                        return open
                    }
                    open.forEach { $0.cancel() }
                    withExtendedLifetime((output, errorPipe, input)) {}
                    if let stop { resolve(.failure(stop)) }
                    return
                }
                let (open, result) = state.withLock { state -> ([any DispatchSourceRead], Result<ProcessOutcome, any Error>) in
                    defer { state.sources = []; state.processGroup = 0 }
                    return (state.sources, .success(ProcessOutcome(status: status, exited: exited, output: state.output,
                                                                   errorOutput: state.errorOutput)))
                }
                open.forEach { $0.cancel() }
                resolve(result)
                withExtendedLifetime((output, errorPipe, input)) {}
            }
        }
        let processSource = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        processSource.setEventHandler { finishExit(nil) }
        state.withLock { $0.processSource = processSource }
        processSource.activate()
        var probeStatus: Int32 = 0
        if waitpid(childPID, &probeStatus, WNOHANG) == childPID { finishExit(probeStatus) }
        request.onLaunch?(childPID)
        if let input, let bytes = request.input { feed(bytes, to: input) }
    }

    /// Stops the child for `failure`: sends the request's stop signal now and SIGKILL after its kill grace
    /// (the exit cancels that). A ``ProcessRequest/CancelBehavior/stop`` run resolves with `failure` at
    /// once; a ``ProcessRequest/CancelBehavior/finish`` run at the exit or at the SIGKILL. A stop before the
    /// launch makes the launch signal the child at once. Only the first stop counts, and none after the
    /// child exited on its own (its outcome is on its way).
    func stop(_ failure: any Error) {
        let first = state.withLock { state -> Bool in
            guard !state.resolved, !state.ended, state.stop == nil else { return false }
            state.stop = failure
            return true
        }
        guard first else { return }
        // Before the signal, so the exit it causes always finds the deadline to cancel.
        if request.stopSignal != SIGKILL {
            killDeadline.schedule(after: request.killGrace) { [self] in
                send(SIGKILL)
                state.withLock { $0.processGroup = 0 }
                // Bounded: a child that does not end even on SIGKILL (stuck in the kernel) does not hold the caller.
                resolve(.failure(failure))
            }
        }
        if request.onCancel == .stop { resolve(.failure(failure)) }
        send(request.stopSignal)
    }

    /// Sends signal `number` to the child while it runs; nothing before its launch or after its exit.
    private func send(_ number: Int32) {
        state.withLock { state in
            if state.processGroup > 0 {
                _ = Darwin.kill(-state.processGroup, number)
            } else if state.pid > 0 {
                _ = Darwin.kill(state.pid, number)
            }
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

    /// A read source on `fd`, the read end of `pipe`, which it makes non-blocking, so the exit drain never
    /// blocks on a pipe a grandchild still holds. Its cancel handler holds `pipe`, so the descriptor stays
    /// open until the (asynchronous) cancel has finished: libdispatch leaves closing it earlier undefined
    /// (another open could reuse the number, and the late unregister would hit that one).
    private func source(_ fd: Int32, of pipe: Pipe, into buffer: WritableKeyPath<State, Data> & Sendable) -> any DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            if drain(fd, into: buffer) { source.cancel() }
        }
        source.setCancelHandler { withExtendedLifetime(pipe) {} }
        state.withLock { $0.sources.append(source) }
        return source
    }

    /// Reads what `fd` holds now without blocking (the descriptor is non-blocking); true at end of file
    /// or on a read error, false when the pipe is empty but still open. Once the run has resolved the
    /// bytes are dropped: nobody reads them, and a child that keeps writing must not grow the buffer.
    @discardableResult
    private func drain(_ fd: Int32, into buffer: WritableKeyPath<State, Data> & Sendable) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                state.withLock { state in
                    guard !state.resolved else { return }
                    state[keyPath: buffer].append(contentsOf: chunk[0..<count])
                }
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

    private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return body(pointers)
    }
}
