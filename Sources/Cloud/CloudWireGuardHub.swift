import CmuxCloudTui
import Foundation

/// The app's one in-process WireGuard tunnel into the user's private Cloud VM
/// network, held by a single `cmux-tui wg hub` child that serves SOCKS5 on an
/// owner-only unix socket. Every headless machine link (`remote connect
/// --wireguard-hub <socket>`) dials its VM through that socket.
///
/// One WireGuard key supports one live session, and the app spawns one link
/// process per machine, so those processes cannot each own a tunnel: the hub is
/// the single owner and the links are its clients. It uses the terminal tunnel
/// role, which is separate from the browser Network Extension tunnel role.
///
/// Lifecycle: the first ``acquire()`` uses the saved config, or enrolls the
/// app identity once when no config exists. It then spawns the hub and
/// resolves once the socket accepts connections.
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
        /// WireGuard config (``VMTunnelManager/enroll(client:deviceName:)`` with the
        /// terminal role in production).
        let enroll: @Sendable () async throws -> Enrollment
        /// The cmux-tui client binary that provides `wg hub`.
        let clientURL: URL
        /// Where the hub's SOCKS5 unix socket lives; the parent directory is 0700.
        let socketURL: URL
        let spawner: any CloudWireGuardHubSpawning
        /// Resolves once `socketPath` accepts a connection; throws on timeout.
        let waitUntilReady: @Sendable (_ socketPath: String) async throws -> Void
        /// Cancellable delay; production uses `ContinuousClock`.
        let sleep: @Sendable (Duration) async throws -> Void
        /// Delays before each restart after an unexpected exit; its count bounds the attempts.
        let restartBackoff: [Duration]
        /// How long the hub outlives its last lease, so a re-link does not pay a fresh handshake.
        let idleGrace: Duration

        static let defaultRestartBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]
        static let defaultIdleGrace: Duration = .seconds(10)
    }

    private enum State {
        case stopped
        case starting(generation: UInt64, task: Task<Ready, Error>)
        case running(Ready)
    }

    private let configuration: Configuration
    private let processHandle = CloudWireGuardHubProcessHandle()
    private var state: State = .stopped
    private var leases: Set<Lease> = []
    /// Keeps the shared terminal carrier ready while signed-in Cloud access is enabled.
    private var prewarmLease: Lease?
    /// Retained after completion: one automatic sequence per Cloud activation, not per fleet poll.
    private var preparationTask: Task<Void, Never>?
    private var pinnedByExternalClient = false
    /// Bumped on every intentional stop so a stale exit callback cannot restart a hub
    /// that was stopped on purpose.
    private var generation: UInt64 = 0
    private var idleStopTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var restartAttempts = 0
    private var lastError: String?
    /// A failed startup process may report termination after its replacement
    /// has started. Only the current child may invalidate the hub's state.
    private var processID: UUID?
    /// A child can exit after readiness wins but before the shared startup task
    /// publishes `.running`. Keep that signal until the state transition commits.
    private var pendingStartupExit: (processID: UUID, status: Int32)?

    init(configuration: Configuration) {
        self.configuration = configuration
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

    /// Schedules account-level preparation without making fleet discovery wait for enrollment.
    /// Repeated refreshes and a first terminal join the same startup and keep one shared claim.
    func prepareForCloudUse() {
        guard !Task.isCancelled, preparationTask == nil else { return }
        preparationTask = Task { [weak self] in
            _ = try? await self?.prewarm()
        }
    }

    /// Keeps one account claim even if startup fails. Explicit link demand can
    /// recover later without losing the Cloud activation's keep-ready policy.
    func prewarm() async throws -> Ready {
        try Task.checkCancellation()
        if prewarmLease == nil {
            let lease = Lease(id: UUID())
            leases.insert(lease)
            prewarmLease = lease
            idleStopTask?.cancel()
            idleStopTask = nil
        }
        return try await ensureRunning()
    }

    /// Releases the account-level preparation claim when its owner no longer needs it.
    func releasePrewarm() {
        guard let prewarmLease else { return }
        self.prewarmLease = nil
        release(prewarmLease)
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
        preparationTask?.cancel()
        preparationTask = nil
        idleStopTask?.cancel()
        idleStopTask = nil
        restartTask?.cancel()
        restartTask = nil
        restartAttempts = 0
        leases.removeAll()
        prewarmLease = nil
        pinnedByExternalClient = false
        if case .starting(_, let task) = state { task.cancel() }
        state = .stopped
        processID = nil
        pendingStartupExit = nil
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
        case .starting(_, let task):
            return try await task.value
        case .stopped:
            break
        }
        let startGeneration = generation
        let task = Task<Ready, Error> { try await self.startWithRecovery(generation: startGeneration) }
        state = .starting(generation: startGeneration, task: task)
        do {
            let ready = try await task.value
            if let pendingStartupExit, processID == pendingStartupExit.processID {
                self.pendingStartupExit = nil
                throw HubError.exitedDuringStart(
                    status: pendingStartupExit.status,
                    output: lastError ?? "hub exited during startup"
                )
            } else if pendingStartupExit != nil {
                // A callback from an older child cannot invalidate this one.
                self.pendingStartupExit = nil
            }
            guard generation == startGeneration,
                  case .starting(let stateGeneration, _) = state,
                  stateGeneration == startGeneration else {
                throw HubError.exitedDuringStart(
                    status: processHandle.exitStatus ?? -1,
                    output: lastError ?? "hub stopped during startup"
                )
            }
            state = .running(ready)
            return ready
        } catch {
            if case .starting(let stateGeneration, _) = state,
               stateGeneration == startGeneration {
                state = .stopped
            }
            lastError = CloudMachineLink.errorText(error)
            throw error
        }
    }

    /// Enrollment and startup recovery belong to the one shared startup task.
    /// Explicit opens and background warmup await the same final result; no
    /// caller can fail early while another caller is still recovering it.
    private func startWithRecovery(generation startGeneration: UInt64) async throws -> Ready {
        let delays = Array(configuration.restartBackoff.prefix(3))
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            guard generation == startGeneration else { throw CancellationError() }
            // Each child owns its own startup-exit signal. A late callback from
            // a failed child cannot poison a later recovery attempt because its
            // process identity no longer matches the replacement.
            pendingStartupExit = nil
            do {
                return try await start(generation: startGeneration)
            } catch {
                try Task.checkCancellation()
                guard generation == startGeneration else { throw CancellationError() }
                lastError = CloudMachineLink.errorText(error)
                guard attempt < delays.count else { throw error }
                try await configuration.sleep(delays[attempt])
            }
        }
        throw HubError.notReady("hub startup failed without a reported error")
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
        let startedProcessID = UUID()
        processID = startedProcessID
        processHandle.replace(with: process)
        let exit = CloudLinkFirstValue<Int32>()
        process.onExit { [weak self] status in
            exit.resolve(status)
            Task { await self?.processDidExit(status: status, generation: startGeneration, processID: startedProcessID) }
        }
        let waitUntilReady = configuration.waitUntilReady
        let outcome: Result<Void, Error> = await withTaskGroup(of: Result<Void, Error>.self) { group in
            group.addTask {
                do {
                    try await waitUntilReady(socketPath)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                if let status = await exit.result {
                    return .failure(HubError.exitedDuringStart(status: status, output: process.outputTail))
                }
                return .failure(HubError.notReady("hub exited"))
            }
            let first = await group.next() ?? .failure(HubError.notReady("no readiness signal"))
            group.cancelAll()
            return first
        }
        switch outcome {
        case .success:
            break
        case .failure(let error):
            let output = process.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if processID == startedProcessID { processID = nil }
            process.terminate()
            let detail = CloudMachineLink.errorText(error)
            if let hubError = error as? HubError {
                let hubDetail = hubError.errorDescription ?? detail
                throw HubError.notReady(output.isEmpty ? hubDetail : "\(hubDetail); hub output: \(output)")
            }
            throw HubError.notReady(output.isEmpty ? detail : "\(detail); hub output: \(output)")
        }
        guard process.isRunning else {
            pendingStartupExit = nil
            throw HubError.exitedDuringStart(status: process.exitStatus ?? -1, output: process.outputTail)
        }
        lastError = nil
        return Ready(socketPath: socketPath, routes: enrollment.routes)
    }

    private func processDidExit(status: Int32, generation exitGeneration: UInt64, processID exitedProcessID: UUID) {
        guard exitGeneration == generation, processID == exitedProcessID else { return }
        switch state {
        case .starting:
            // Preserve the exit until ensureRunning commits the ready state. If
            // readiness won immediately before this callback, dropping it would
            // publish a running hub whose child is already dead.
            pendingStartupExit = (exitedProcessID, status)
            removeSocketFile()
            return
        case .running:
            state = .stopped
        case .stopped:
            return
        }
        processID = nil
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
            self.stopIfStillUnused(generation: stopGeneration)
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
    func terminate()
    /// Registers the one exit callback; a process that already exited calls it at once.
    func onExit(_ handler: @escaping @Sendable (Int32) -> Void)
}

protocol CloudWireGuardHubSpawning: Sendable {
    func spawn(executable: URL, arguments: [String]) throws -> any CloudWireGuardHubProcess
}

/// The hub's current child, reachable without actor isolation so app termination can
/// kill it synchronously. The short lock protects only the process-pointer handoff
/// between the hub actor and `applicationWillTerminate`.
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

    var exitStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return process?.exitStatus
    }
}
