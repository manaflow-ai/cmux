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
            lastError = Self.errorText(error)
            removeInviteFile()
            throw LinkError.spawnFailed(error.localizedDescription)
        }
        self.process = process
        drainStderr(stderr.fileHandleForReading)

        // The first connection-snapshot line names the socket; later lines only update
        // transport topology and are ignored.
        let socketPath: String = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    if let socket = CmuxTuiSnapshotParser.localSocket(fromLinkLine: line) {
                        return socket
                    }
                }
                return nil
            }
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
        try process.run()
        let outFD = stdout.fileHandleForReading
        let errFD = stderr.fileHandleForReading
        // Pipes drain on detached tasks so a chatty command cannot deadlock on a full
        // pipe; the blocking wait lives off the cooperative pool too. A deadline
        // terminates the child, which unblocks the wait with a non-zero status.
        async let outData = Task.detached { outFD.readDataToEndOfFile() }.value
        async let errData = Task.detached { errFD.readDataToEndOfFile() }.value
        let deadline = Task<Bool, Never> {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return false
            }
            process.terminate()
            return true
        }
        await Task.detached { process.waitUntilExit() }.value
        deadline.cancel()
        let timedOut = await deadline.value
        let out = await outData
        let err = await errData
        if timedOut { throw LinkError.timedOut }
        guard process.terminationStatus == 0 else {
            let text = String(data: err, encoding: .utf8) ?? ""
            let fallback = String(data: out, encoding: .utf8) ?? ""
            throw LinkError.exited(status: process.terminationStatus, output: text.isEmpty ? fallback : text)
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
        let handle = stdout.fileHandleForReading
        Task.detached {
            do {
                for try await line in handle.bytes.lines where !line.isEmpty {
                    continuation.yield()
                }
            } catch {
                // The link's own exit handler reports the state change.
            }
        }
    }

    private func drainStderr(_ handle: FileHandle) {
        Task.detached { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    await self?.recordStderr(line)
                }
            } catch {}
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
