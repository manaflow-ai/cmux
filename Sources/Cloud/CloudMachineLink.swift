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

    struct ForwardedPort: Sendable, Equatable {
        let port: Int
        let url: URL
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
    /// True only after the control plane supplied native relay grants for this
    /// link. Surface ports use this to avoid returning a stale provider-preview
    /// URL during a transport rollout.
    private(set) var nativeRelayActive = false

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
    /// Relay credentials are shared by the headless link and local forwards. The
    /// file paths stay fixed while the ticket contents rotate, so cmux-tui can
    /// read a fresh credential whenever it reconnects without seeing a Stack token.
    private var relayTicketFiles: [String: URL] = [:]
    private var relayRefreshTask: Task<Void, Never>?
    private var forwardProcesses: [Int: Process] = [:]
    private var forwardProcessTokens: [Int: UUID] = [:]
    private var forwardURLs: [Int: URL] = [:]
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
    /// Relay tickets are kept in short-lived mode-0600 files because the CLI
    /// rejects inline credentials and must be able to refresh them on reconnect.
    func connect(
        route: String,
        session: String,
        invitationURI: String?,
        relayGrants: [VMCmuxRemoteEndpoint.RelayGrant] = [],
        relayRefresh: (@Sendable () async throws -> [VMCmuxRemoteEndpoint.RelayGrant])? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> Connected {
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
        do {
            try installRelayTicketFiles(relayGrants)
        } catch {
            removeInviteFile()
            removeRelayTicketFiles()
            throw error
        }
        let relayArguments: [CloudTuiCommandLine.RelayAccess]
        do {
            relayArguments = try relayAccess(for: relayGrants)
        } catch {
            removeInviteFile()
            removeRelayTicketFiles()
            throw error
        }
        let process = Process()
        process.executableURL = clientURL
        process.arguments = CloudTuiCommandLine.linkArguments(
            route: route,
            deviceName: CloudTuiClientPaths.deviceName(),
            stateDir: paths.stateDir.path,
            inviteFilePath: inviteFilePath,
            relayAccess: relayArguments
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
            removeRelayTicketFiles()
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
                process.terminate()
                throw LinkError.timedOut
            }
            return socket
        }
        guard process.isRunning else {
            removeRelayTicketFiles()
            throw LinkError.exited(status: process.terminationStatus, output: stderrTail.joined(separator: "\n"))
        }
        let connected = Connected(socketPath: socketPath, session: session)
        self.connected = connected
        state = .connected
        nativeRelayActive = !relayGrants.isEmpty
        startRelayRefresh(grants: relayGrants, refresh: relayRefresh)
        startEventsSubscription(socketPath: socketPath)
        changesContinuation.yield()
        return connected
    }

    func disconnect() {
        relayRefreshTask?.cancel()
        relayRefreshTask = nil
        for process in forwardProcesses.values { process.terminate() }
        forwardProcesses.removeAll()
        forwardProcessTokens.removeAll()
        forwardURLs.removeAll()
        eventsProcess?.terminate()
        eventsProcess = nil
        process?.terminate()
        process = nil
        connected = nil
        nativeRelayActive = false
        state = .unavailable
        removeInviteFile()
        removeRelayTicketFiles()
        changesContinuation.finish()
    }

    /// Starts (or reuses) a local loopback forward for one remote port. The
    /// cmux-tui forward command owns the authenticated TcpTunnel connection;
    /// this actor only supervises its process and exposes the local URL.
    func forward(
        port: Int,
        endpoint: VMOpenPortEndpoint,
        timeout: Duration = .seconds(60)
    ) async throws -> ForwardedPort {
        guard endpoint.transport == "cmux-remote",
              let route = endpoint.route, !route.isEmpty,
              !endpoint.relays.isEmpty,
              (1...65535).contains(port) else {
            throw LinkError.spawnFailed("Cloud VM did not return a native relay port endpoint.")
        }
        if let existing = forwardProcesses[port], existing.isRunning, let url = forwardURLs[port] {
            return ForwardedPort(port: port, url: url)
        }
        if let stale = forwardProcesses.removeValue(forKey: port) { stale.terminate() }
        forwardProcessTokens[port] = nil
        forwardURLs[port] = nil
        try paths.ensureStateDir()

        let token = UUID()
        do {
            try installOrRefreshRelayTicketFiles(endpoint.relays)
        } catch {
            throw error
        }
        let relayAccess = try relayAccess(for: endpoint.relays)

        let process = Process()
        process.executableURL = clientURL
        process.arguments = CloudTuiCommandLine.forwardArguments(
            route: route,
            workspaceRoot: "/root",
            port: port,
            relayAccess: relayAccess,
            inviteFilePath: nil
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
            Task { await self?.forwardProcessDidExit(port: port, token: token, status: status) }
        }
        let firstURL = CloudLinkFirstValue<URL>()
        let stdoutLines = CloudLinkPipe.lines(from: stdout.fileHandleForReading)
        Task.detached {
            for await line in stdoutLines {
                if let url = URL(string: line.trimmingCharacters(in: .whitespacesAndNewlines)),
                   let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    firstURL.resolve(url)
                }
            }
            firstURL.resolve(nil)
        }
        drainStderr(stderr.fileHandleForReading)
        do {
            try process.run()
        } catch {
            throw LinkError.spawnFailed(error.localizedDescription)
        }
        forwardProcesses[port] = process
        forwardProcessTokens[port] = token
        var url: URL?
        do {
            url = try await withThrowingTaskGroup(of: URL?.self) { group in
                group.addTask { await firstURL.result }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        } catch {
            process.terminate()
            throw error
        }
        guard let url else {
            process.terminate()
            throw LinkError.timedOut
        }
        guard process.isRunning else {
            throw LinkError.exited(status: process.terminationStatus, output: stderrTail.joined(separator: "\n"))
        }
        forwardURLs[port] = url
        return ForwardedPort(port: port, url: url)
    }

    /// Returns a live local listener without minting another control-plane
    /// endpoint. The process check closes the small race where the termination
    /// callback has not reached this actor yet.
    func forwardedURL(port: Int) -> URL? {
        guard let process = forwardProcesses[port], process.isRunning else { return nil }
        return forwardURLs[port]
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
        relayRefreshTask?.cancel()
        relayRefreshTask = nil
        for forward in forwardProcesses.values { forward.terminate() }
        forwardProcesses.removeAll()
        forwardProcessTokens.removeAll()
        forwardURLs.removeAll()
        process = nil
        connected = nil
        nativeRelayActive = false
        removeInviteFile()
        removeRelayTicketFiles()
        if state != .unavailable {
            state = status == 0 ? .unavailable : .error
            lastError = status == 0 ? nil : LinkError.exited(status: status, output: stderrTail.joined(separator: "\n")).errorDescription
        }
        changesContinuation.yield()
        changesContinuation.finish()
    }

    private func forwardProcessDidExit(port: Int, token: UUID, status: Int32) {
        guard forwardProcessTokens[port] == token else { return }
        forwardProcessTokens[port] = nil
        forwardProcesses[port] = nil
        forwardURLs[port] = nil
        if status != 0 { changesContinuation.yield() }
    }

    private func removeInviteFile() {
        if let inviteFileURL {
            try? FileManager.default.removeItem(at: inviteFileURL)
            self.inviteFileURL = nil
        }
    }

    private func removeRelayTicketFiles() {
        for url in relayTicketFiles.values {
            try? FileManager.default.removeItem(at: url)
        }
        relayTicketFiles.removeAll()
        // Do not remove the shared per-machine directory. A second app instance
        // can have a live forward for the same VM; only this link's file names
        // are owned here. The directory contains no credential after the files
        // above are removed and remains mode 0700.
    }

    // MARK: - relay credentials

    private var relayTicketDirectory: URL {
        // Keep credentials below the app-owned 0700 state directory, not in
        // the shared system temporary directory. The prefix prevents a
        // malformed machine id from becoming `.` or `..` if this path is ever
        // constructed from an untrusted API response.
        let safeID = machineID
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
            .prefix(80)
        return paths.stateDir
            .appendingPathComponent("relay-tickets", isDirectory: true)
            .appendingPathComponent("machine-\(safeID.isEmpty ? "unknown" : String(safeID))", isDirectory: true)
    }

    private func ensureRelayTicketDirectory() throws {
        try FileManager.default.createDirectory(
            at: relayTicketDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: relayTicketDirectory.path)
    }

    private func installRelayTicketFiles(
        _ grants: [VMCmuxRemoteEndpoint.RelayGrant]
    ) throws {
        removeRelayTicketFiles()
        guard !grants.isEmpty else { return }
        try ensureRelayTicketDirectory()
        var installed: [String: URL] = [:]
        do {
            for grant in grants {
                guard installed[grant.route] == nil else {
                    throw LinkError.spawnFailed("Cloud VM returned a repeated relay route.")
                }
                let url = relayTicketDirectory
                    .appendingPathComponent("cmux-cloud-relay-ticket-\(UUID().uuidString.lowercased())")
                try writeRelayTicket(grant.ticket, to: url)
                installed[grant.route] = url
            }
            relayTicketFiles = installed
        } catch {
            for url in installed.values { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// A port endpoint is minted by a separate request, so refresh its ticket
    /// contents before starting a forward. The route set must remain stable,
    /// because cmux-tui receives the route list only at process launch.
    private func installOrRefreshRelayTicketFiles(
        _ grants: [VMCmuxRemoteEndpoint.RelayGrant]
    ) throws {
        guard !grants.isEmpty else {
            throw LinkError.spawnFailed("Cloud VM returned no relay credentials.")
        }
        let routes = Set(grants.map(\.route))
        if relayTicketFiles.isEmpty {
            try installRelayTicketFiles(grants)
            return
        }
        guard routes == Set(relayTicketFiles.keys) else {
            throw LinkError.spawnFailed("Cloud VM changed its relay routes while the link was active.")
        }
        for grant in grants {
            guard let url = relayTicketFiles[grant.route] else {
                throw LinkError.spawnFailed("Cloud VM returned an unknown relay route.")
            }
            try writeRelayTicket(grant.ticket, to: url)
        }
    }

    private func relayAccess(
        for grants: [VMCmuxRemoteEndpoint.RelayGrant]
    ) throws -> [CloudTuiCommandLine.RelayAccess] {
        try grants.map { grant in
            guard let url = relayTicketFiles[grant.route] else {
                throw LinkError.spawnFailed("Cloud VM relay credential file is unavailable.")
            }
            return CloudTuiCommandLine.RelayAccess(route: grant.route, slot: grant.slot, ticketFilePath: url.path)
        }
    }

    private func writeRelayTicket(_ ticket: String, to url: URL) throws {
        guard !ticket.isEmpty, ticket.count <= 4096,
              !ticket.contains(where: { $0 == "\n" || $0 == "\r" || $0.isWhitespace }) else {
            throw LinkError.spawnFailed("Cloud VM returned an invalid relay ticket.")
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".cmux-cloud-relay-ticket-\(UUID().uuidString.lowercased())")
        do {
            try (ticket + "\n").data(using: .utf8)!.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func startRelayRefresh(
        grants: [VMCmuxRemoteEndpoint.RelayGrant],
        refresh: (@Sendable () async throws -> [VMCmuxRemoteEndpoint.RelayGrant])?
    ) {
        relayRefreshTask?.cancel()
        relayRefreshTask = nil
        guard let refresh, !grants.isEmpty else { return }
        relayRefreshTask = Task { [weak self] in
            await self?.relayRefreshLoop(initialGrants: grants, refresh: refresh)
        }
    }

    private func relayRefreshLoop(
        initialGrants: [VMCmuxRemoteEndpoint.RelayGrant],
        refresh: @Sendable () async throws -> [VMCmuxRemoteEndpoint.RelayGrant]
    ) async {
        var grants = initialGrants
        var retrySeconds: UInt64 = 5
        while !Task.isCancelled {
            let now = Int64(Date().timeIntervalSince1970)
            let refreshAt = grants.map(\.refreshAfterUnix).min() ?? now + 60
            let waitSeconds = max(1, min(120, refreshAt - now))
            do {
                try await Task.sleep(for: .seconds(waitSeconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                let next = try await refresh()
                guard !Task.isCancelled, state == .connected else { return }
                try installOrRefreshRelayTicketFiles(next)
                grants = next
                retrySeconds = 5
            } catch {
                #if DEBUG
                cmuxDebugLog("cloud.link.relayRefreshFailed machine=\(machineID) error=\(Self.errorText(error))")
                #endif
                // Keep the previous file until its expiry, then retry with a
                // bounded delay. cmux-tui's own reconnect loop will fail over
                // between shards while this broker request is unavailable.
                do {
                    try await Task.sleep(for: .seconds(retrySeconds))
                } catch {
                    return
                }
                retrySeconds = min(retrySeconds * 2, 60)
            }
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
    /// unterminated line is delivered at EOF. One consumer.
    static func lines(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
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

    private final class LineBuffer {
        private var pending = Data()

        func append(_ data: Data) -> [String] {
            pending.append(data)
            let split = CloudLinkPipe.splitLines(pending)
            pending = split.rest
            return split.lines
        }

        func flush() -> String? {
            defer { pending = Data() }
            guard !pending.isEmpty else { return nil }
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
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]
    private var cancelledWaiters: Set<UUID> = []

    func resolve(_ value: Value?) {
        lock.lock()
        guard case .pending = state else {
            lock.unlock()
            return
        }
        state = .done(value)
        let waiting = Array(waiters.values)
        waiters = [:]
        cancelledWaiters.removeAll()
        lock.unlock()
        for waiter in waiting {
            waiter.resume(returning: value)
        }
    }

    var result: Value? {
        get async {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if case .done(let value) = state {
                        lock.unlock()
                        continuation.resume(returning: value)
                    } else if Task.isCancelled || cancelledWaiters.remove(waiterID) != nil {
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else {
                        waiters[waiterID] = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                cancel(waiterID)
            }
        }
    }

    private func cancel(_ waiterID: UUID) {
        lock.lock()
        if let continuation = waiters.removeValue(forKey: waiterID) {
            lock.unlock()
            continuation.resume(returning: nil)
        } else if case .pending = state {
            // Cancellation can race registration. Keep a marker for the
            // operation closure, which removes it while holding the same lock.
            cancelledWaiters.insert(waiterID)
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}
