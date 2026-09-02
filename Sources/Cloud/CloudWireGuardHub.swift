import Foundation

/// The app's one in-process WireGuard tunnel into the user's private Cloud VM
/// network, held by a single `cmux-tui wg hub` child that serves SOCKS5 on an
/// owner-only unix socket. Every headless machine link (`remote connect
/// --wireguard-hub <socket>`) dials its VM through that socket.
///
/// One WireGuard key supports one live session, and the app spawns one link
/// process per machine, so those processes cannot each own a tunnel: the hub is
/// the single owner and the links are its clients. Its identity is
/// ``VMTunnelManager/Identity/app``, distinct from the `cmux vpn up` system
/// interface, so the two never fight over the server-side endpoint.
///
/// Lifecycle: the first ``acquire()`` enrolls the app identity, writes the
/// config, spawns the hub, and resolves once the socket accepts connections.
/// Leases are released as links end; ``idleGrace`` after the last release the
/// hub stops. A hub that exits while leases are held is restarted with bounded
/// backoff (the links' own reconnect loops then find the socket again). A pane
/// that runs the full client (`cmux vm tui`) is a process the app cannot watch,
/// so ``pinForExternalClient()`` keeps the hub for the rest of the app session.
///
/// The spawner, the readiness probe, and the sleeper are injected so the whole
/// lifecycle is testable without a binary or a network.
actor CloudWireGuardHub {
    /// One link's claim on the running hub; release it when the link ends.
    struct Lease: Sendable, Hashable {
        fileprivate let id: UUID
    }

    /// What a client needs to dial through the hub.
    struct Ready: Sendable, Equatable {
        /// The SOCKS5 unix socket the hub listens on.
        let socketPath: String
        /// The tunnel's `AllowedIPs`: only hosts inside them belong on the hub.
        let routes: [String]
    }

    /// A read-only view for diagnostics (`vm.tunnel_status`).
    struct Status: Sendable, Equatable {
        let running: Bool
        let socketPath: String?
        let leases: Int
        let pinnedByExternalClient: Bool
        let restartAttempts: Int
        let lastError: String?
    }

    enum HubError: Error, LocalizedError, Equatable {
        case exitedDuringStart(status: Int32, output: String)
        case notReady(String)
        case spawnFailed(String)
        case restartsExhausted(String)

        var errorDescription: String? {
            switch self {
            case .exitedDuringStart(let status, let output):
                let tail = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                return "cmux-tui wg hub exited with status \(status) before its socket was ready" + (tail.isEmpty ? "." : ": \(tail)")
            case .notReady(let detail):
                return "cmux-tui wg hub did not start listening: \(detail)"
            case .spawnFailed(let detail):
                return "cmux-tui wg hub could not be started: \(detail)"
            case .restartsExhausted(let detail):
                return "cmux-tui wg hub keeps exiting; giving up until the next link: \(detail)"
            }
        }
    }

    /// The result of enrolling the app identity: where the config landed and what it routes.
    struct Enrollment: Sendable, Equatable {
        let configPath: String
        let routes: [String]
    }

    struct Configuration: Sendable {
        /// Enrolls the app tunnel identity with the control plane and writes the
        /// wg-quick config (``VMTunnelManager/enroll(client:deviceName:)`` with the
        /// `.app` identity in production).
        let enroll: @Sendable () async throws -> Enrollment
        /// The cmux-tui client binary that provides `wg hub`.
        let clientURL: URL
        /// Where the hub's SOCKS5 unix socket lives; the parent directory is 0700.
        let socketURL: URL
        let spawner: any CloudWireGuardHubSpawning
        /// The one sanity check after the hub announces readiness: does a listener
        /// accept at the announced socket. Injected so tests need no real socket.
        let verifySocket: @Sendable (_ socketPath: String) -> Bool
        /// How long to wait for the hub's `hub-ready` line before giving up.
        let readyTimeout: Duration
        /// Cancellable delay; production uses `ContinuousClock`.
        let sleep: @Sendable (Duration) async throws -> Void
        /// Delays before each restart after an unexpected exit; its count bounds the attempts.
        let restartBackoff: [Duration]
        /// How long the hub outlives its last lease, so a re-link does not pay a fresh handshake.
        let idleGrace: Duration

        static let defaultRestartBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]
        static let defaultIdleGrace: Duration = .seconds(10)
        /// Enrollment is done before the spawn; the hub only has to handshake and bind.
        static let defaultReadyTimeout: Duration = .seconds(20)
    }

    private enum State {
        case stopped
        case starting(Task<Ready, Error>)
        case running(Ready)
    }

    private let configuration: Configuration
    private let processHandle = CloudWireGuardHubProcessHandle()
    private var state: State = .stopped
    private var leases: Set<Lease> = []
    private var pinnedByExternalClient = false
    /// Bumped on every intentional stop so a stale exit callback cannot restart a hub
    /// that was stopped on purpose.
    private var generation: UInt64 = 0
    private var idleStopTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var restartAttempts = 0
    private var lastError: String?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// The production hub for the bundled client, writing under `~/.cmuxterm/wireguard`.
    static func production(clientURL: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> CloudWireGuardHub {
        let manager = VMTunnelManager(home: home, identity: .app)
        let configuration = Configuration(
            enroll: {
                let client = await MainActor.run { VMClient.shared }
                guard let client else {
                    throw VMClientError.malformedResponse("Cloud VM client is not available (not signed in).")
                }
                let state = try await manager.enroll(client: client)
                return Enrollment(configPath: state.configPath, routes: state.endpoint.routes)
            },
            clientURL: clientURL,
            socketURL: manager.stateDir.appendingPathComponent("hub-\(getpid()).sock", isDirectory: false),
            spawner: CloudWireGuardHubProcessSpawner(),
            verifySocket: { socketPath in CloudWireGuardHubReadyEvent.accepts(socketPath) },
            readyTimeout: Configuration.defaultReadyTimeout,
            sleep: { duration in try await ContinuousClock().sleep(for: duration) },
            restartBackoff: Configuration.defaultRestartBackoff,
            idleGrace: Configuration.defaultIdleGrace
        )
        return CloudWireGuardHub(configuration: configuration)
    }

    /// Whether `host` (a literal IP) is one the hub would route: inside the
    /// enrolled `AllowedIPs` when known, else inside the private address ranges.
    /// Public hosts never take the hub.
    static func routesHost(_ host: String, enrolledRoutes: [String]) -> Bool {
        if !enrolledRoutes.isEmpty {
            return IPNetworkPrefix.host(host, isWithinAnyOf: enrolledRoutes)
        }
        return IPNetworkPrefix.isPrivateAddress(host)
    }

    /// Claims the hub for one link, starting it if needed.
    func acquire() async throws -> (lease: Lease, ready: Ready) {
        let lease = Lease(id: UUID())
        leases.insert(lease)
        idleStopTask?.cancel()
        idleStopTask = nil
        // New demand resets the crash budget; a successful start alone does not, so a
        // hub that listens and then dies cannot loop forever on the shortest delay.
        restartAttempts = 0
        do {
            let ready = try await ensureRunning()
            return (lease, ready)
        } catch {
            leases.remove(lease)
            scheduleIdleStopIfUnused()
            throw error
        }
    }

    /// Ends one link's claim; the hub stops ``Configuration/idleGrace`` after the last one.
    func release(_ lease: Lease) {
        leases.remove(lease)
        scheduleIdleStopIfUnused()
    }

    /// Keeps the hub for the rest of the app session on behalf of a client process the
    /// app cannot watch (the `cmux vm tui` pane), starting it if needed.
    func pinForExternalClient() async throws -> Ready {
        pinnedByExternalClient = true
        idleStopTask?.cancel()
        idleStopTask = nil
        restartAttempts = 0
        return try await ensureRunning()
    }

    /// Stops the hub on purpose (sign-out, revoke); leases are dropped, no restart follows.
    func stop() {
        generation &+= 1
        idleStopTask?.cancel()
        idleStopTask = nil
        restartTask?.cancel()
        restartTask = nil
        restartAttempts = 0
        leases.removeAll()
        pinnedByExternalClient = false
        if case .starting(let task) = state { task.cancel() }
        state = .stopped
        processHandle.terminate()
        removeSocketFile()
    }

    /// Kills the hub synchronously from `applicationWillTerminate`, where nothing may await.
    nonisolated func terminateForAppQuit() {
        processHandle.terminate()
    }

    func status() -> Status {
        let socketPath: String?
        switch state {
        case .running(let ready): socketPath = ready.socketPath
        case .starting, .stopped: socketPath = nil
        }
        return Status(
            running: socketPath != nil,
            socketPath: socketPath,
            leases: leases.count,
            pinnedByExternalClient: pinnedByExternalClient,
            restartAttempts: restartAttempts,
            lastError: lastError
        )
    }

    // MARK: - internals

    private var wanted: Bool { !leases.isEmpty || pinnedByExternalClient }

    private func ensureRunning() async throws -> Ready {
        switch state {
        case .running(let ready):
            return ready
        case .starting(let task):
            return try await task.value
        case .stopped:
            break
        }
        let startGeneration = generation
        let task = Task<Ready, Error> { try await self.start(generation: startGeneration) }
        state = .starting(task)
        do {
            let ready = try await task.value
            if case .starting(let current) = state, current == task {
                state = .running(ready)
            }
            return ready
        } catch {
            if case .starting(let current) = state, current == task {
                state = .stopped
            }
            lastError = CloudMachineLink.errorText(error)
            throw error
        }
    }

    private func start(generation startGeneration: UInt64) async throws -> Ready {
        let enrollment = try await configuration.enroll()
        try Task.checkCancellation()
        guard generation == startGeneration else { throw CancellationError() }
        removeSocketFile()
        let socketPath = configuration.socketURL.path
        let process: any CloudWireGuardHubProcess
        do {
            process = try configuration.spawner.spawn(
                executable: configuration.clientURL,
                arguments: CloudTuiCommandLine.wireGuardHubArguments(configPath: enrollment.configPath, socketPath: socketPath)
            )
        } catch {
            throw HubError.spawnFailed(error.localizedDescription)
        }
        processHandle.replace(with: process)
        let exit = CloudLinkFirstValue<Int32>()
        process.onExit { [weak self] status in
            exit.resolve(status)
            Task { await self?.processDidExit(status: status, generation: startGeneration) }
        }
        // Readiness is the hub's own `hub-ready` stdout line (the same contract as a
        // sidecar's `connection-snapshot` line): whichever comes first of that line,
        // the process exiting, or the bounded timeout decides the start.
        let lines = process.stdoutLines
        let sleep = configuration.sleep
        let readyTimeout = configuration.readyTimeout
        let outcome: Result<CloudWireGuardHubReadyEvent, Error> = await withTaskGroup(of: Result<CloudWireGuardHubReadyEvent, Error>.self) { group in
            group.addTask {
                for await line in lines {
                    if let event = CloudWireGuardHubReadyEvent(line: line) { return .success(event) }
                }
                return .failure(HubError.notReady("stdout closed before hub-ready"))
            }
            group.addTask {
                if let status = await exit.result {
                    return .failure(HubError.exitedDuringStart(status: status, output: process.outputTail))
                }
                return .failure(HubError.notReady("hub exited"))
            }
            group.addTask {
                do {
                    try await sleep(readyTimeout)
                } catch {
                    return .failure(CancellationError())
                }
                return .failure(HubError.notReady("no hub-ready line within \(readyTimeout)"))
            }
            let first = await group.next() ?? .failure(HubError.notReady("no readiness signal"))
            group.cancelAll()
            return first
        }
        let event: CloudWireGuardHubReadyEvent
        switch outcome {
        case .success(let ready):
            event = ready
        case .failure(let error):
            process.terminate()
            if let hubError = error as? HubError { throw hubError }
            throw HubError.notReady(CloudMachineLink.errorText(error))
        }
        guard process.isRunning else {
            throw HubError.exitedDuringStart(status: process.exitStatus ?? -1, output: process.outputTail)
        }
        guard configuration.verifySocket(event.socketPath) else {
            process.terminate()
            throw HubError.notReady("hub announced \(event.socketPath) but nothing accepts there")
        }
        lastError = nil
        // The hub's own view of AllowedIPs is authoritative; the enrollment response is
        // the fallback for a hub build that omits them.
        return Ready(socketPath: event.socketPath, routes: event.routes.isEmpty ? enrollment.routes : event.routes)
    }

    private func processDidExit(status: Int32, generation exitGeneration: UInt64) {
        guard exitGeneration == generation else { return }
        guard case .running = state else { return }
        state = .stopped
        removeSocketFile()
        guard wanted else { return }
        lastError = "cmux-tui wg hub exited with status \(status)"
        guard restartAttempts < configuration.restartBackoff.count else {
            lastError = HubError.restartsExhausted(lastError ?? "").errorDescription
            return
        }
        let delay = configuration.restartBackoff[restartAttempts]
        restartAttempts += 1
        let restartGeneration = generation
        restartTask?.cancel()
        restartTask = Task { [configuration] in
            do {
                try await configuration.sleep(delay)
            } catch {
                return
            }
            await self.restartIfStillWanted(generation: restartGeneration)
        }
    }

    private func restartIfStillWanted(generation restartGeneration: UInt64) async {
        restartTask = nil
        guard restartGeneration == generation, wanted, case .stopped = state else { return }
        _ = try? await ensureRunning()
    }

    private func scheduleIdleStopIfUnused() {
        guard !wanted, idleStopTask == nil else { return }
        switch state {
        case .stopped: return
        case .starting, .running: break
        }
        let stopGeneration = generation
        idleStopTask = Task { [configuration] in
            do {
                try await configuration.sleep(configuration.idleGrace)
            } catch {
                return
            }
            await self.stopIfStillUnused(generation: stopGeneration)
        }
    }

    private func stopIfStillUnused(generation stopGeneration: UInt64) {
        idleStopTask = nil
        guard stopGeneration == generation, !wanted else { return }
        stop()
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(at: configuration.socketURL)
    }
}

/// A hub child process as the lifecycle sees it; Foundation `Process` in production,
/// a scripted fake in tests.
protocol CloudWireGuardHubProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// The exit status once the process has ended.
    var exitStatus: Int32? { get }
    /// The last few lines the process wrote, for error messages.
    var outputTail: String { get }
    /// The process's stdout, one line at a time; ends at EOF. Consumed once by the hub.
    var stdoutLines: AsyncStream<String> { get }
    func terminate()
    /// Registers the one exit callback; a process that already exited calls it at once.
    func onExit(_ handler: @escaping @Sendable (Int32) -> Void)
}

protocol CloudWireGuardHubSpawning: Sendable {
    func spawn(executable: URL, arguments: [String]) throws -> any CloudWireGuardHubProcess
}

/// The hub's current child, reachable without actor isolation so app termination can
/// kill it synchronously.
final class CloudWireGuardHubProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: (any CloudWireGuardHubProcess)?

    func replace(with process: any CloudWireGuardHubProcess) {
        lock.lock()
        let previous = self.process
        self.process = process
        lock.unlock()
        previous?.terminate()
    }

    func terminate() {
        lock.lock()
        let current = process
        process = nil
        lock.unlock()
        current?.terminate()
    }
}
