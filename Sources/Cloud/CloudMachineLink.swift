import Foundation

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
        case timedOut

        var errorDescription: String? {
            switch self {
            case .clientMissing:
                return "No cmux-tui client is bundled with this build (Contents/Resources/bin/cmux-tui) and CMUX_TUI_CLIENT is unset."
            case .spawnFailed(let detail):
                return "cmux-tui could not be started: \(detail)"
            case .exited(let status, let output):
                let tail = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                return "cmux-tui link exited with status \(status)" + (tail.isEmpty ? "" : ": \(tail)")
            case .timedOut:
                return "cmux-tui link did not report a socket within the connect timeout."
            }
        }
    }

    let machineID: String
    private let clientURL: URL
    private let paths: CloudTuiClientPaths

    private(set) var state: SurfaceLinkState = .connecting
    private(set) var lastError: String?

    /// Human-readable text for a link failure. Typed cmux errors describe
    /// themselves (`VMClientError` is `CustomStringConvertible`, the link and
    /// manager errors are `LocalizedError`); only foreign errors fall back to
    /// Foundation's "The operation couldn't be completed. (… error 1.)".
    nonisolated static func errorText(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        // Swift errors print their `description` (or case name) here; a real
        // NSError prints "Error Domain=… Code=…", where localizedDescription
        // is the readable form.
        let described = String(describing: error)
        if described.isEmpty || described.hasPrefix("Error Domain=") {
            return error.localizedDescription
        }
        return described
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
    /// Notification upserts parsed off the same event stream (`CloudMachineNotificationEvent`),
    /// already sanitized and capped; snapshot replays are never on it. Bounded: under a
    /// flood the oldest unread notification is dropped rather than growing memory. Ends
    /// with `changes` when the link dies.
    let notifications: AsyncStream<CloudMachineNotificationEvent>
    private let notificationsContinuation: AsyncStream<CloudMachineNotificationEvent>.Continuation
    /// Identifies the current events subprocess so a stale reader task cannot restart it.
    private var eventsGeneration: UInt64 = 0
    private var eventsRestartWindowStart: UInt64 = 0
    private var eventsRestartCount = 0

    /// Lines the events pipe may hold ahead of its reader; ticks are idempotent and
    /// notifications are best-effort, so newest-wins is the right overflow policy.
    static let eventsLineBacklog = 1024
    /// Restarts of a dead events subscription tolerated per minute while the link lives.
    static let maxEventsRestartsPerMinute = 5

    init(machineID: String, clientURL: URL, paths: CloudTuiClientPaths) {
        self.machineID = machineID
        self.clientURL = clientURL
        self.paths = paths
        (changes, changesContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (notifications, notificationsContinuation) = AsyncStream<CloudMachineNotificationEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
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
            lastError = Self.errorText(error)
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
        async let outData = CloudLinkPipe.readToEnd(stdout.fileHandleForReading)
        async let errData = CloudLinkPipe.readToEnd(stderr.fileHandleForReading)
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
        guard status == 0 else {
            let text = String(data: err, encoding: .utf8) ?? ""
            let fallback = String(data: out, encoding: .utf8) ?? ""
            throw LinkError.exited(status: status, output: text.isEmpty ? fallback : text)
        }
        return out
    }

    // MARK: - internals

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
        eventsGeneration &+= 1
        let generation = eventsGeneration
        let continuation = changesContinuation
        let notificationsContinuation = notificationsContinuation
        let lines = CloudLinkPipe.lines(
            from: stdout.fileHandleForReading,
            bufferingPolicy: .bufferingNewest(Self.eventsLineBacklog)
        )
        Task.detached { [weak self] in
            for await line in lines where !line.isEmpty {
                continuation.yield()
                // Only delta notification upserts raise notifications; the snapshot item
                // replays the daemon's durable ledger on every (re)connect and is skipped.
                if case .delta(let events) = CloudMachineNotificationEvent.parse(line: line) {
                    for event in events {
                        notificationsContinuation.yield(event)
                    }
                }
            }
            // EOF with the link still alive means the daemon ended just this stream (a
            // `gap` after a slow read, a resync); the link's own exit handler reports link
            // death. Restart so notifications are not silently lost for the link's lifetime.
            await self?.eventsSubscriptionDidEnd(generation: generation, socketPath: socketPath)
        }
    }

    private func eventsSubscriptionDidEnd(generation: UInt64, socketPath: String) async {
        guard generation == eventsGeneration else { return }
        eventsProcess = nil
        guard state == .connected, connected != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if now &- eventsRestartWindowStart > 60_000_000_000 {
            eventsRestartWindowStart = now
            eventsRestartCount = 0
        }
        guard eventsRestartCount < Self.maxEventsRestartsPerMinute else { return }
        eventsRestartCount += 1
        try? await Task.sleep(for: .seconds(1))
        guard generation == eventsGeneration, state == .connected, connected != nil, eventsProcess == nil else { return }
        startEventsSubscription(socketPath: socketPath)
        changesContinuation.yield()
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
        notificationsContinuation.finish()
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
    /// Raw chunks as they arrive; ends at EOF. One consumer.
    static func chunks(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// Lines (without their newline; a trailing CR is dropped) as they arrive; a final
    /// unterminated line is delivered at EOF. One consumer. A line longer than
    /// `LineBuffer.maxLineBytes` is discarded rather than buffered (see there).
    static func lines(
        from handle: FileHandle,
        bufferingPolicy: AsyncStream<String>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let buffer = LineBuffer()
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    if let tail = buffer.flush() { continuation.yield(tail) }
                    continuation.finish()
                    return
                }
                for line in buffer.append(data) {
                    continuation.yield(line)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// Everything up to EOF.
    static func readToEnd(_ handle: FileHandle) async -> Data {
        var data = Data()
        for await chunk in chunks(from: handle) {
            data.append(chunk)
        }
        return data
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
        /// The daemon caps one message at 4 MiB; a longer "line" is not a message but a
        /// broken or hostile peer. It is discarded up to its next newline instead of being
        /// held in memory for as long as the peer withholds the newline.
        static let maxLineBytes = 4 * 1024 * 1024

        private var pending = Data()
        private var discardingOversizedLine = false

        func append(_ data: Data) -> [String] {
            var data = data
            if discardingOversizedLine {
                guard let newline = data.firstIndex(of: 0x0A) else { return [] }
                data = Data(data[data.index(after: newline)...])
                discardingOversizedLine = false
            }
            pending.append(data)
            let split = CloudLinkPipe.splitLines(pending)
            pending = split.rest
            if pending.count > Self.maxLineBytes {
                pending = Data()
                discardingOversizedLine = true
            }
            return split.lines
        }

        func flush() -> String? {
            defer {
                pending = Data()
                discardingOversizedLine = false
            }
            guard !pending.isEmpty, !discardingOversizedLine else { return nil }
            var line = String(decoding: pending, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
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
