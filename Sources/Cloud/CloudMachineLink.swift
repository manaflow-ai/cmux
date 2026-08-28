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
    struct Connected: Sendable, Equatable {
        let socketPath: String
        let session: String
    }

    enum LinkError: Error, LocalizedError {
        case clientMissing
        case spawnFailed(String)
        case exited(status: Int32, output: String)
        case outputLimitExceeded
        case timedOut

        var errorDescription: String? {
            switch self {
            case .clientMissing:
                return String(localized: "cloud.link.clientMissing", defaultValue: "The cloud terminal client is not available. Reinstall cmux and try again.")
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
            guard case .exited(_, let output) = self else { return .other }
            return CloudMachineLink.remoteFailureCode(in: output)
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
    private var eventsProcess: Process?
    private var inviteFileURL: URL?
    private var stderrTail: [String] = []

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
        try paths.ensureStateDir()
        var inviteFilePath: String?
        if let invitationURI, !invitationURI.isEmpty {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-cloud-link-invite-\(UUID().uuidString.lowercased())")
            try (invitationURI + "\n").data(using: .utf8)!.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            Task { await self?.linkProcessDidExit(status: status) }
        }
        state = .connecting
        lastError = nil
        do {
            try process.run()
        } catch {
            state = .error
            lastError = Self.errorText(LinkError.spawnFailed(error.localizedDescription))
            removeInviteFile()
            throw LinkError.spawnFailed(error.localizedDescription)
        }
        self.process = process
        drainStderr(stderr.fileHandleForReading)

        // The first connection-snapshot line names the socket; later lines only update
        // transport topology and are ignored — but stdout keeps draining for the
        // process's whole life so the client never blocks on a full pipe.
        let firstSocket = CloudLinkFirstValue<String>()
        let stdoutLines = CloudLinkPipe.lines(from: stdout.fileHandleForReading)
        Task.detached {
            for await line in stdoutLines {
                if let socket = CmuxTuiSnapshotParser.localSocket(fromLinkLine: line) {
                    firstSocket.resolve(socket)
                }
            }
            firstSocket.resolve(nil)
        }
        let socketPath: String = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { await firstSocket.result }
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
        guard process.isRunning else {
            throw LinkError.exited(status: process.terminationStatus, output: stderrTail.joined(separator: "\n"))
        }
        let connected = Connected(socketPath: socketPath, session: session)
        self.connected = connected
        state = .connected
        startEventsSubscription(socketPath: socketPath)
        changesContinuation.yield()
        return connected
    }

    func disconnect() {
        eventsProcess?.terminate()
        eventsProcess = nil
        process?.terminate()
        process = nil
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
        try process.run()
        async let outData = CloudLinkPipe.readToEndResult(
            stdout.fileHandleForReading,
            maximumBytes: CloudLinkPipe.maximumCommandOutputBytes
        )
        async let errData = CloudLinkPipe.readToEndResult(
            stderr.fileHandleForReading,
            maximumBytes: CloudLinkPipe.maximumDiagnosticOutputBytes
        )
        let deadline = Task<Bool, Never> {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            process.terminate()
            return true
        }
        let status = await exit.result ?? process.terminationStatus
        deadline.cancel()
        let timedOut = await deadline.value
        let out = await outData
        let err = await errData
        if timedOut { throw LinkError.timedOut }
        if out.truncated || err.truncated { throw LinkError.outputLimitExceeded }
        guard status == 0 else {
            let text = String(decoding: err.data, as: UTF8.self)
            let fallback = String(decoding: out.data, as: UTF8.self)
            throw LinkError.exited(status: status, output: text.isEmpty ? fallback : text)
        }
        return out.data
    }

    // MARK: - internals

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
        do {
            try process.run()
        } catch {
            return
        }
        eventsProcess = process
        let continuation = changesContinuation
        let lines = CloudLinkPipe.lines(from: stdout.fileHandleForReading)
        Task.detached {
            for await line in lines where !line.isEmpty {
                continuation.yield()
            }
            // The link's own exit handler reports the state change.
        }
    }

    private func drainStderr(_ handle: FileHandle) {
        let lines = CloudLinkPipe.lines(from: handle)
        Task.detached { [weak self] in
            for await line in lines {
                await self?.recordStderr(line)
            }
        }
    }

    private func recordStderr(_ line: String) {
        stderrTail.append(line)
        if stderrTail.count > 20 { stderrTail.removeFirst(stderrTail.count - 20) }
    }

    private func linkProcessDidExit(status: Int32) {
        eventsProcess?.terminate()
        eventsProcess = nil
        process = nil
        connected = nil
        removeInviteFile()
        if state != .unavailable {
            state = status == 0 ? .unavailable : .error
            lastError = status == 0 ? nil : LinkError.exited(status: status, output: stderrTail.joined(separator: "\n")).errorDescription
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

    /// Everything up to EOF, capped at ``maximumCommandOutputBytes``.
    static func readToEnd(_ handle: FileHandle) async -> Data {
        await readToEndResult(handle, maximumBytes: maximumCommandOutputBytes).data
    }

    /// Drains a pipe without buffering more than `maximumBytes`.
    static func readToEndResult(_ handle: FileHandle, maximumBytes: Int) async -> ReadResult {
        let reader = BoundedReadState(maximumBytes: max(0, maximumBytes))
        reader.install(on: handle)
        return await reader.result()
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

    private final class LineBuffer {
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

/// Accumulates one process pipe on its readability callback and resolves one
/// continuation at EOF. The lock protects only this synchronous callback seam;
/// callers never access the mutable buffer directly.
private final class BoundedReadState: @unchecked Sendable {
    private struct State: Sendable {
        var data = Data()
        var truncated = false
        var finished = false
    }

    private let maximumBytes: Int
    private let state: OSAllocatedUnfairLock<State>
    private let completion = CloudLinkFirstValue<CloudLinkPipe.ReadResult>()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    func install(on handle: FileHandle) {
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
