import Darwin
import Foundation
import os

/// One headless cmux-tui link to a cloud machine's daemon: a `remote connect --headless`
/// client process whose local mux socket the app drives for snapshots, events, and
/// terminal creation. The pane's own `vm-tui-connect` link is separate; this one belongs
/// to the sidebar and the `vm.*` tree methods and never touches a tty.
///
/// Lifecycle: `connect` spawns the client and resolves once the first
/// `connection-snapshot` line names the socket; the process is kept until `disconnect`
/// or until it exits on its own (machine slept, route expired), which flips the state
/// and ends the `changes` stream so the owner can re-link on demand.
actor CloudMachineLink {
    private static let maximumInvitationBytes = 64 * 1024

    struct Connected: Sendable, Equatable {
        let socketPath: String
        let session: String
    }

    enum LinkError: Error, LocalizedError {
        case clientMissing
        case alreadyConnecting
        case spawnFailed
        case exited(status: Int32, code: RemoteFailureCode)
        case outputLimitExceeded
        case timedOut

        var errorDescription: String? {
            switch self {
            case .clientMissing:
                return String(localized: "cloud.link.clientMissing", defaultValue: "The cloud terminal client is not available. Reinstall cmux and try again.")
            case .alreadyConnecting:
                return String(localized: "cloud.link.alreadyConnecting", defaultValue: "The cloud terminal is already connecting. Try again.")
            case .spawnFailed, .outputLimitExceeded:
                return String(localized: "cloud.link.operationFailed", defaultValue: "The cloud terminal operation failed. Try again.")
            case .exited:
                return String(localized: "cloud.link.exited", defaultValue: "The cloud terminal client stopped unexpectedly. Try again.")
            case .timedOut:
                return String(localized: "cloud.link.timedOut", defaultValue: "The cloud terminal connection timed out. Try again.")
            }
        }

        /// A small internal classification used for recovery without retaining or
        /// displaying the remote command's diagnostic text.
        var remoteFailureCode: RemoteFailureCode {
            guard case .exited(_, let code) = self else { return .other }
            return code
        }

        enum RemoteFailureCode: Equatable, Sendable {
            case selectorNotFound
            case other
        }
    }

    let machineID: String
    private let clientURL: URL
    private let paths: CloudTuiClientPaths

    private(set) var state: SurfaceLinkState = .connecting
    private(set) var lastError: String?

    /// Human-readable text for a link failure.
    ///
    /// Remote command output is untrusted. Only link-owned error cases receive a
    /// stable local message; every other error is intentionally collapsed to the
    /// same message so a server path, token, or parser detail cannot reach the UI.
    nonisolated static func errorText(_ error: Error) -> String {
        if let linkError = error as? LinkError, let text = linkError.errorDescription, !text.isEmpty {
            return text
        }
        return String(localized: "cloud.link.operationFailed", defaultValue: "The cloud terminal operation failed. Try again.")
    }
    private(set) var connected: Connected?

    // Foundation `Process` and its pipes are actor-isolated state; every callback hops
    // back into the actor through a Task, so nothing else touches them.
    private var process: Process?
    private var processStopper: CloudLinkProcessStopper?
    private var processGeneration: UUID?
    private var eventsProcess: Process?
    private var eventsProcessStopper: CloudLinkProcessStopper?
    private var inviteFileURL: URL?

    /// One tick per daemon-side change (from `session current events`) or link state
    /// change; ends when the link dies.
    let changes: AsyncStream<Void>
    private let changesContinuation: AsyncStream<Void>.Continuation

    init(machineID: String, clientURL: URL, paths: CloudTuiClientPaths) {
        self.machineID = machineID
        self.clientURL = clientURL
        self.paths = paths
        (changes, changesContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var isConnected: Bool { connected != nil && state == .connected }

    /// Spawns the headless client against `route` and waits for its local socket.
    func connect(route: String, session: String, invitationURI: String?, timeout: Duration = .seconds(60)) async throws -> Connected {
        if let connected, state == .connected { return connected }
        if process != nil { throw LinkError.alreadyConnecting }
        try paths.ensureStateDir()
        var inviteFilePath: String?
        if let invitationURI, !invitationURI.isEmpty {
            let url = try Self.writeInvitationFile(invitationURI)
            inviteFileURL = url
            inviteFilePath = url.path
        }
        let process = Process()
        process.executableURL = clientURL
        process.arguments = CloudTuiCommandLine.linkArguments(
            route: route,
            deviceName: CloudTuiClientPaths.deviceName(),
            stateDir: paths.stateDir.path,
            inviteFilePath: inviteFilePath
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_REMOTE_STATE_DIR"] = paths.stateDir.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let stopper = CloudLinkProcessStopper(
            process: process,
            handles: [stdout.fileHandleForReading, stderr.fileHandleForReading]
        )
        let generation = UUID()
        let exit = CloudLinkFirstValue<Int32>()
        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            exit.resolve(status)
            Task { await self?.linkProcessDidExit(status: status, generation: generation) }
        }
        state = .connecting
        lastError = nil
        self.process = process
        self.processStopper = stopper
        self.processGeneration = generation
        do {
            try process.run()
        } catch {
            state = .error
            exit.resolve(nil)
            stopper.stop()
            lastError = Self.errorText(LinkError.spawnFailed)
            removeInviteFile()
            self.process = nil
            self.processStopper = nil
            self.processGeneration = nil
            throw LinkError.spawnFailed
        }
        drainAndDiscard(stderr.fileHandleForReading)

        // The first connection-snapshot line names the socket; later lines only update
        // transport topology and are ignored — but stdout keeps draining for the
        // process's whole life so the client never blocks on a full pipe.
        // Search the stream directly instead of putting lines into a finite queue.
        // A peer can write arbitrary diagnostics before the snapshot; queueing those
        // lines could evict the only snapshot and turn a valid connection into a
        // timeout. The scanner keeps draining after it finds the socket so the child
        // cannot block on a full stdout pipe.
        let firstSocketTask = Task {
            await CloudLinkPipe.firstMatchingLine(from: stdout.fileHandleForReading) { line in
                CmuxTuiSnapshotParser.localSocket(fromLinkLine: line)
            }
        }
        let socketPath: String
        do {
            socketPath = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: String?.self) { group in
                    group.addTask { await firstSocketTask.value }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return nil
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next(), let socket = first else {
                        throw LinkError.timedOut
                    }
                    return socket
                }
            } onCancel: {
                firstSocketTask.cancel()
                stopper.stop()
            }
        } catch {
            firstSocketTask.cancel()
            stopper.stop()
            self.process = nil
            self.processStopper = nil
            self.processGeneration = nil
            removeInviteFile()
            if Task.isCancelled { throw CancellationError() }
            state = .error
            lastError = Self.errorText(error)
            throw error
        }
        guard process.isRunning else {
            stopper.stop()
            self.process = nil
            self.processStopper = nil
            self.processGeneration = nil
            removeInviteFile()
            throw LinkError.exited(status: process.terminationStatus, code: .other)
        }
        let connected = Connected(socketPath: socketPath, session: session)
        self.connected = connected
        state = .connected
        startEventsSubscription(socketPath: socketPath)
        changesContinuation.yield()
        return connected
    }

    func disconnect() {
        eventsProcessStopper?.stop()
        eventsProcessStopper = nil
        eventsProcess = nil
        processStopper?.stop()
        processStopper = nil
        process = nil
        processGeneration = nil
        connected = nil
        state = .unavailable
        removeInviteFile()
        changesContinuation.finish()
    }

    /// Runs one cmux-tui command against the link's socket and returns its stdout.
    func run(arguments: [String], timeout: Duration = .seconds(30)) async throws -> Data {
        let process = Process()
        process.executableURL = clientURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Pipes drain on GCD (``CloudLinkPipe``) so a chatty command cannot deadlock on a
        // full pipe and no cooperative thread sits in read(2) or waitpid(2); the exit
        // arrives through the termination handler. A deadline terminates the child,
        // which ends both drains with a non-zero status.
        let exit = CloudLinkFirstValue<Int32>()
        process.terminationHandler = { exited in exit.resolve(exited.terminationStatus) }
        let stopper = CloudLinkProcessStopper(
            process: process,
            handles: [stdout.fileHandleForReading, stderr.fileHandleForReading]
        )
        let outReader = BoundedReadState(maximumBytes: CloudLinkPipe.maximumCommandOutputBytes)
        outReader.install(on: stdout.fileHandleForReading)
        let errReader = BoundedReadState(maximumBytes: CloudLinkPipe.maximumDiagnosticOutputBytes)
        errReader.install(on: stderr.fileHandleForReading)
        let outTask = Task {
            await outReader.result()
        }
        let errTask = Task {
            await errReader.result()
        }
        do {
            try process.run()
        } catch {
            exit.resolve(nil)
            stopper.stop()
            outReader.cancel()
            errReader.cancel()
            _ = await outTask.value
            _ = await errTask.value
            throw LinkError.spawnFailed
        }
        let deadline = Task<Bool, Never> {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            stopper.stop()
            outReader.cancel()
            errReader.cancel()
            return true
        }
        let status = await withTaskCancellationHandler {
            await exit.result ?? process.terminationStatus
        } onCancel: {
            stopper.stop()
            outReader.cancel()
            errReader.cancel()
            exit.resolve(nil)
        }
        deadline.cancel()
        let timedOut = await deadline.value
        let out = await outTask.value
        let err = await errTask.value
        stopper.stop()
        process.terminationHandler = nil
        if Task.isCancelled { throw CancellationError() }
        if timedOut { throw LinkError.timedOut }
        if out.truncated || err.truncated { throw LinkError.outputLimitExceeded }
        guard status == 0 else {
            let text = String(decoding: err.data, as: UTF8.self)
            let fallback = String(decoding: out.data, as: UTF8.self)
            throw LinkError.exited(
                status: status,
                code: Self.remoteFailureCode(in: text.isEmpty ? fallback : text)
            )
        }
        return out.data
    }

    // MARK: - internals

    private static func writeInvitationFile(_ invitationURI: String) throws -> URL {
        guard let data = (invitationURI + "\n").data(using: .utf8),
              data.count <= maximumInvitationBytes else {
            throw LinkError.outputLimitExceeded
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cloud-link-invite-\(UUID().uuidString.lowercased())")
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw LinkError.spawnFailed }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            return url
        } catch {
            // `FileHandle` owns the descriptor, including the failure path.
            // Closing it here also prevents a descriptor leak before the file is removed.
            try? FileManager.default.removeItem(at: url)
            throw LinkError.spawnFailed
        }
    }

    private nonisolated static func remoteFailureCode(in output: String) -> LinkError.RemoteFailureCode {
        let normalized = output.lowercased()
        if normalized.contains("selector.not_found") || normalized.contains("no terminal matches") {
            return .selectorNotFound
        }
        return .other
    }

    private func startEventsSubscription(socketPath: String) {
        let process = Process()
        process.executableURL = clientURL
        process.arguments = CloudTuiCommandLine.eventsArguments(socketPath: socketPath)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let stopper = CloudLinkProcessStopper(process: process, handles: [stdout.fileHandleForReading])
        do {
            try process.run()
        } catch {
            stopper.stop()
            return
        }
        eventsProcess = process
        eventsProcessStopper = stopper
        let continuation = changesContinuation
        let lines = CloudLinkPipe.lines(from: stdout.fileHandleForReading)
        Task.detached {
            for await line in lines where !line.isEmpty {
                continuation.yield()
            }
            // The link's own exit handler reports the state change.
        }
    }

    private func drainAndDiscard(_ handle: FileHandle) {
        let lines = CloudLinkPipe.lines(from: handle)
        Task.detached {
            for await _ in lines {}
        }
    }

    private func linkProcessDidExit(status: Int32, generation: UUID) {
        guard processGeneration == generation else { return }
        eventsProcessStopper?.stop()
        eventsProcessStopper = nil
        eventsProcess = nil
        processStopper = nil
        process = nil
        processGeneration = nil
        connected = nil
        removeInviteFile()
        if state != .unavailable {
            state = status == 0 ? .unavailable : .error
            lastError = status == 0 ? nil : LinkError.exited(status: status, code: .other).errorDescription
        }
        changesContinuation.yield()
        changesContinuation.finish()
    }

    private func removeInviteFile() {
        if let inviteFileURL {
            try? FileManager.default.removeItem(at: inviteFileURL)
            self.inviteFileURL = nil
        }
    }
}

/// Owns a child process and the parent-side read handles for its complete lifecycle.
/// Cancellation closes the readers and sends TERM followed by KILL when the child does
/// not exit immediately, so a timeout cannot leave an orphan holding a route or pipe.
final class CloudLinkProcessStopper: @unchecked Sendable {
    private let process: Process
    private let handles: [FileHandle]
    private let lock = NSLock()
    private var stopped = false

    init(process: Process, handles: [FileHandle]) {
        self.process = process
        self.handles = handles
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        let identifier = process.processIdentifier
        if process.isRunning, identifier > 1 {
            process.terminate()
            if process.isRunning {
                _ = Darwin.kill(identifier, SIGKILL)
            }
        }
        for handle in handles {
            try? handle.close()
        }
    }
}

/// GCD-driven reading of the link's child-process pipes. `FileHandle.bytes.lines` and
/// `readDataToEndOfFile()` park a cooperative thread in read(2) for as long as the pipe
/// stays open; every linked machine held three that way (link stdout, link stderr, the
/// events stream) and each `run` three more, so a few machines exhausted the pool —
/// `Task.sleep` deadlines stopped firing, links sat in "connecting" for minutes past
/// their timeout, and every socket command crawled. `readabilityHandler` runs on a GCD
/// queue and costs the pool nothing.
enum CloudLinkPipe {
    /// A remote client can emit arbitrary bytes. These limits keep a stalled or
    /// malicious client from turning a link into an unbounded memory sink.
    static let maximumLineBytes = 64 * 1024
    static let maximumCommandOutputBytes = 8 * 1024 * 1024
    static let maximumDiagnosticOutputBytes = 256 * 1024
    private static let streamBufferCapacity = 64

    struct ReadResult: Sendable {
        let data: Data
        let truncated: Bool
    }

    /// Raw chunks as they arrive; ends at EOF. One consumer.
    static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingOldest(streamBufferCapacity)) { continuation in
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    continuation.finish()
                } else {
                    // The stream is only used for best-effort event draining. Keep
                    // the oldest chunks so a link's first connection snapshot is
                    // not displaced by a flood of later diagnostics.
                    _ = continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// Lines (without their newline; a trailing CR is dropped) as they arrive; a final
    /// unterminated line is delivered at EOF. Oversized lines are discarded through
    /// their newline so a remote peer cannot grow the pending line forever.
    static func lines(from handle: FileHandle, maximumLineBytes: Int = Self.maximumLineBytes) -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingOldest(streamBufferCapacity)) { continuation in
            let buffer = LineBuffer(maximumBytes: maximumLineBytes)
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    if let tail = buffer.flush() { _ = continuation.yield(tail) }
                    continuation.finish()
                    return
                }
                for line in buffer.append(data) {
                    _ = continuation.yield(line)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// Finds the first line for which ``matching`` returns a value while continuously
    /// draining the handle. The reader remains installed after a match and discards
    /// later lines until EOF, preventing a successful link from deadlocking on a noisy
    /// child process. Cancellation before a match closes the reader and resolves nil;
    /// cancellation after a match leaves the drain alive for the child lifecycle.
    static func firstMatchingLine(
        from handle: FileHandle,
        maximumLineBytes: Int = Self.maximumLineBytes,
        matching: @escaping @Sendable (String) -> String?
    ) async -> String? {
        let reader = FirstMatchingLineReader(
            handle: handle,
            maximumLineBytes: maximumLineBytes,
            matching: matching
        )
        reader.install()
        return await withTaskCancellationHandler {
            await reader.result()
        } onCancel: {
            reader.cancel()
        }
    }

    /// Everything up to EOF, capped at ``maximumCommandOutputBytes``.
    static func readToEnd(_ handle: FileHandle) async -> Data {
        await readToEndResult(handle, maximumBytes: maximumCommandOutputBytes).data
    }

    /// Drains a pipe without buffering more than `maximumBytes`.
    static func readToEndResult(_ handle: FileHandle, maximumBytes: Int) async -> ReadResult {
        let reader = BoundedReadState(maximumBytes: max(0, maximumBytes))
        reader.install(on: handle)
        return await withTaskCancellationHandler {
            await reader.result()
        } onCancel: {
            reader.cancel()
        }
    }

    /// Splits a byte stream into lines; only ever touched from the handle's GCD queue.
    static func splitLines(_ data: Data) -> (lines: [String], rest: Data) {
        var lines: [String] = []
        var pending = data
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
            pending = pending[pending.index(after: newline)...]
        }
        return (lines, Data(pending))
    }

    final class LineBuffer {
        private let maximumBytes: Int
        private var pending = Data()
        private var discardingOversizedLine = false

        init(maximumBytes: Int) {
            self.maximumBytes = max(1, maximumBytes)
        }

        func append(_ data: Data) -> [String] {
            var lines: [String] = []
            for byte in data {
                if discardingOversizedLine {
                    if byte == 0x0A {
                        discardingOversizedLine = false
                    }
                    continue
                }
                if byte == 0x0A {
                    if pending.last == 0x0D { pending.removeLast() }
                    lines.append(String(decoding: pending, as: UTF8.self))
                    pending.removeAll(keepingCapacity: true)
                } else if pending.count < maximumBytes {
                    pending.append(byte)
                } else {
                    pending.removeAll(keepingCapacity: false)
                    discardingOversizedLine = true
                }
            }
            return lines
        }

        func flush() -> String? {
            defer {
                pending.removeAll(keepingCapacity: false)
                discardingOversizedLine = false
            }
            guard !discardingOversizedLine, !pending.isEmpty else { return nil }
            if pending.last == 0x0D { pending.removeLast() }
            var line = String(decoding: pending, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
    }
}

/// Owns the first-snapshot scan. The FileHandle retains the readability closure, so
/// the scanner continues to drain after the async caller receives its match. Access to
/// lifecycle state is synchronized because cancellation can race a GCD read callback.
private final class FirstMatchingLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let buffer: CloudLinkPipe.LineBuffer
    private let matching: @Sendable (String) -> String?
    private let value = CloudLinkFirstValue<String>()
    private let lock = NSLock()
    private let bufferLock = NSLock()
    private var matched = false
    private var finished = false
    private var cancelled = false

    init(
        handle: FileHandle,
        maximumLineBytes: Int,
        matching: @escaping @Sendable (String) -> String?
    ) {
        self.handle = handle
        self.buffer = CloudLinkPipe.LineBuffer(maximumBytes: maximumLineBytes)
        self.matching = matching
    }

    func install() {
        handle.readabilityHandler = { [self] fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                finish()
                return
            }
            bufferLock.lock()
            let lines = buffer.append(data)
            bufferLock.unlock()
            for line in lines {
                lock.lock()
                let shouldMatch = !cancelled && !matched
                lock.unlock()
                guard shouldMatch, let result = matching(line) else { continue }
                lock.lock()
                guard !cancelled, !matched else {
                    lock.unlock()
                    continue
                }
                matched = true
                lock.unlock()
                value.resolve(result)
            }
        }
    }

    func result() async -> String? {
        await value.result
    }

    func cancel() {
        lock.lock()
        guard !finished, !matched else {
            lock.unlock()
            return
        }
        cancelled = true
        finished = true
        lock.unlock()
        handle.readabilityHandler = nil
        value.resolve(nil)
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let hadMatch = matched
        lock.unlock()
        handle.readabilityHandler = nil
        if !hadMatch {
            bufferLock.lock()
            let tail = buffer.flush()
            bufferLock.unlock()
            if let tail, let result = matching(tail) {
                lock.lock()
                if !cancelled && !matched {
                    matched = true
                    lock.unlock()
                    value.resolve(result)
                    return
                }
                lock.unlock()
            }
            value.resolve(nil)
        }
    }
}

/// Accumulates one process pipe on its readability callback and resolves one
/// continuation at EOF. The lock protects only this synchronous callback seam;
/// callers never access the mutable buffer directly.
final class BoundedReadState: @unchecked Sendable {
    private struct State: Sendable {
        var data = Data()
        var truncated = false
        var finished = false
    }

    private let maximumBytes: Int
    private let state: OSAllocatedUnfairLock<State>
    private let completion = CloudLinkFirstValue<CloudLinkPipe.ReadResult>()
    private let handleLock = NSLock()
    private var installedHandle: FileHandle?

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    func install(on handle: FileHandle) {
        handleLock.lock()
        installedHandle = handle
        handleLock.unlock()
        handle.readabilityHandler = { [weak self] fileHandle in
            guard let self else { return }
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
                self.finish()
            } else {
                self.consume(data)
            }
        }
    }

    func result() async -> CloudLinkPipe.ReadResult {
        await completion.result ?? CloudLinkPipe.ReadResult(data: Data(), truncated: true)
    }

    func cancel() {
        handleLock.lock()
        let handle = installedHandle
        installedHandle = nil
        handleLock.unlock()
        handle?.readabilityHandler = nil
        let result: CloudLinkPipe.ReadResult? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            state.truncated = true
            return CloudLinkPipe.ReadResult(data: state.data, truncated: true)
        }
        if let result { completion.resolve(result) }
    }

    private func consume(_ chunk: Data) {
        state.withLock { state in
            guard !state.finished else { return }
            let remaining = maximumBytes - state.data.count
            guard remaining > 0 else {
                state.truncated = true
                return
            }
            if chunk.count <= remaining {
                state.data.append(chunk)
            } else {
                state.data.append(chunk.prefix(remaining))
                state.truncated = true
            }
        }
    }

    private func finish() {
        let result: CloudLinkPipe.ReadResult? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            return CloudLinkPipe.ReadResult(data: state.data, truncated: state.truncated)
        }
        handleLock.lock()
        installedHandle = nil
        handleLock.unlock()
        if let result { completion.resolve(result) }
    }
}

/// A value resolved at most once from a GCD callback and awaited from Swift concurrency;
/// `resolve(nil)` finishes it without a value (EOF before the line, no exit status).
final class CloudLinkFirstValue<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case done(Value?)
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var waiters: [CheckedContinuation<Value?, Never>] = []

    func resolve(_ value: Value?) {
        lock.lock()
        guard case .pending = state else {
            lock.unlock()
            return
        }
        state = .done(value)
        let waiting = waiters
        waiters = []
        lock.unlock()
        for waiter in waiting {
            waiter.resume(returning: value)
        }
    }

    var result: Value? {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if case .done(let value) = state {
                    lock.unlock()
                    continuation.resume(returning: value)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }
}
