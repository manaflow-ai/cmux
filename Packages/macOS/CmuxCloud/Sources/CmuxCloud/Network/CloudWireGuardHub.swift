import CmuxAuthRuntime
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
public actor CloudWireGuardHub {
    /// One link's claim on the running hub; release it when the link ends.
    public struct Lease: Sendable, Hashable {
        fileprivate let id: UUID
    }

    /// What a client needs to dial through the hub.
    public struct Ready: Sendable, Equatable {
        public init(
            socketPath: String,
            routes: [String]
        ) {
            self.socketPath = socketPath
            self.routes = routes
        }

        /// The SOCKS5 unix socket the hub listens on.
        public let socketPath: String
        /// The tunnel's `AllowedIPs`: only hosts inside them belong on the hub.
        public let routes: [String]
    }

    /// A read-only view for diagnostics (`vm.tunnel_status`).
    public struct Status: Sendable, Equatable {
        public let running: Bool
        public let socketPath: String?
        public let leases: Int
        public let pinnedByExternalClient: Bool
        public let restartAttempts: Int
        public let lastError: String?

        public init(
            running: Bool,
            socketPath: String?,
            leases: Int,
            pinnedByExternalClient: Bool,
            restartAttempts: Int,
            lastError: String?
        ) {
            self.running = running
            self.socketPath = socketPath
            self.leases = leases
            self.pinnedByExternalClient = pinnedByExternalClient
            self.restartAttempts = restartAttempts
            self.lastError = lastError
        }
    }

    public enum HubError: Error, LocalizedError, Equatable {
        case exitedDuringStart(status: Int32, output: String)
        case notReady(String)
        case spawnFailed(String)
        case restartsExhausted(String)

        public var errorDescription: String? {
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
    public struct Enrollment: Sendable, Equatable {
        public init(
            configPath: String,
            routes: [String]
        ) {
            self.configPath = configPath
            self.routes = routes
        }

        public let configPath: String
        public let routes: [String]
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
    /// Identity and account scope of the task retained in ``preparationTask``.
    /// The identity fences a replaced unscoped warmup from mutating a newer
    /// activation attempt.
    private var preparationID: UUID?
    private var preparationScope: AuthenticatedTeamScope?
    private var pinnedByExternalClient = false
    /// The authenticated account/team that produced the running enrollment.
    /// Activation refreshes preserve the carrier when this scope is unchanged.
    private var activeTeamScope: AuthenticatedTeamScope?
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
    private var refreshTask: Task<Ready, Error>?
    private var lastRefresh: ContinuousClock.Instant?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Whether `host` (a literal IP) is one the hub would route: inside the
    /// enrolled `AllowedIPs` when known, else inside the private address ranges.
    /// Public hosts never take the hub.
    public static func routesHost(_ host: String, enrolledRoutes: [String]) -> Bool {
        if !enrolledRoutes.isEmpty {
            return IPNetworkPrefix.host(host, isWithinAnyOf: enrolledRoutes)
        }
        return IPNetworkPrefix.isPrivateAddress(host)
    }

    public func readyRouting(anyOf hosts: [String]) async throws -> Ready {
        let ready = try await ensureRunning()
        scheduleIdleStopIfUnused()
        guard configuration.refreshEnrollment != nil,
              !hosts.contains(where: { Self.routesHost($0, enrolledRoutes: ready.routes) }) else { return ready }
        if let refreshTask { return try await refreshTask.value }
        let now = configuration.now()
        if let lastRefresh, lastRefresh.duration(to: now) < .seconds(15) { return ready }
        let refreshGeneration = generation
        let task = Task<Ready, Error> { [weak self] in
            guard let self else { throw HubError.notReady("hub deallocated") }
            await self.markRefreshStarted()
            let enrollment = try await self.configuration.refreshEnrollment!()
            return try await self.completeRefresh(enrollment, refreshGeneration: refreshGeneration)
        }
        refreshTask = task
        do { let result = try await task.value; refreshTask = nil; return result }
        catch { refreshTask = nil; throw error }
    }

    private func markRefreshStarted() {
        lastRefresh = configuration.now()
    }

    private func completeRefresh(_ enrollment: Enrollment, refreshGeneration: UInt64) async throws -> Ready {
        let restarted = finishRefresh(enrollment, refreshGeneration: refreshGeneration)
        // Sign-out during refresh intentionally cancels private-route callers instead of restarting the hub.
        if !restarted && generation != refreshGeneration { throw CancellationError() }
        let refreshed = try await ensureRunning()
        scheduleIdleStopIfUnused()
        return refreshed
    }

    private func finishRefresh(_ enrollment: Enrollment, refreshGeneration: UInt64) -> Bool {
        guard generation == refreshGeneration else { return false }
        lastRefresh = configuration.now()
        guard case .running(let ready) = state, ready.routes != enrollment.routes else { return false }
        generation &+= 1
        restartTask?.cancel(); restartTask = nil
        idleStopTask?.cancel(); idleStopTask = nil
        processHandle.terminate()
        removeSocketFile()
        state = .stopped
        return true
    }

    /// Claims the hub for one link, starting it if needed.
    public func acquire() async throws -> (lease: Lease, ready: Ready) {
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

    /// Schedules account-level preparation without making activation or fleet
    /// discovery wait for enrollment. Repeated refreshes and a first terminal
    /// join the same startup and keep one shared claim. The optional scope is
    /// used by first-use activation so a background task cannot enroll a
    /// different account if sign-out or team selection changes while it runs.
    public func prepareForCloudUse(
        allowWhenCloudDisabled: Bool = false,
        expectedTeamScope: AuthenticatedTeamScope? = nil
    ) {
        guard !Task.isCancelled else { return }
        if let preparationTask {
            // Activation publishes its marker before the registry's observer
            // can schedule its ordinary, unscoped warmup. Replace that first
            // task with the account-fenced activation attempt instead of
            // silently dropping the expected scope.
            if let expectedTeamScope, preparationScope != expectedTeamScope {
                preparationTask.cancel()
                self.preparationTask = nil
                preparationID = nil
                preparationScope = nil
            } else {
                return
            }
        }
        let preparationID = UUID()
        preparationScope = expectedTeamScope
        preparationTask = Task { [weak self] in
            _ = try? await self?.prewarm(
                allowWhenCloudDisabled: allowWhenCloudDisabled,
                expectedTeamScope: expectedTeamScope,
                preparationID: preparationID
            )
        }
    }

    /// Cancels the activation-owned preparation attempt and releases only its
    /// account-level claim. Existing link leases remain untouched.
    public func cancelPreparation() async {
        let task = preparationTask
        let hasOtherUsers = leases.count > (prewarmLease == nil ? 0 : 1) || pinnedByExternalClient
        task?.cancel()
        // If preparation is the only owner, invalidate its shared startup
        // task before awaiting it. A readiness probe may otherwise be parked
        // indefinitely while this cleanup waits for the cancelled waiter.
        if task != nil, !hasOtherUsers {
            stop(preservingPreparationTask: true)
            await task?.value
        }
        preparationTask = nil
        preparationID = nil
        preparationScope = nil
        releasePrewarm()
    }

    /// Keeps one account claim even if startup fails. Explicit link demand can
    /// recover later without losing the Cloud activation's keep-ready policy.
    public func prewarm(
        allowWhenCloudDisabled: Bool = false,
        expectedTeamScope: AuthenticatedTeamScope? = nil
    ) async throws -> Ready {
        try await prewarm(
            allowWhenCloudDisabled: allowWhenCloudDisabled,
            expectedTeamScope: expectedTeamScope,
            preparationID: nil
        )
    }

    private func prewarm(
        allowWhenCloudDisabled: Bool,
        expectedTeamScope: AuthenticatedTeamScope?,
        preparationID: UUID?
    ) async throws -> Ready {
        try Task.checkCancellation()
        if let preparationID {
            guard self.preparationID == preparationID else { throw CancellationError() }
        }
        if allowWhenCloudDisabled, activeTeamScope != expectedTeamScope {
            // Activation is the account-fenced handoff from a disabled local
            // marker. Drop any stale carrier before enrolling with the scope
            // captured by this attempt; a running hub cannot be assumed to
            // belong to the current account after sign-out/team changes.
            resetForScopeChange()
            try Task.checkCancellation()
        }
        if prewarmLease == nil {
            let lease = Lease(id: UUID())
            leases.insert(lease)
            prewarmLease = lease
            idleStopTask?.cancel()
            idleStopTask = nil
        }
        let ready = try await ensureRunning(
            allowWhenCloudDisabled: allowWhenCloudDisabled,
            expectedTeamScope: expectedTeamScope
        )
        if let preparationID {
            guard self.preparationID == preparationID else { throw CancellationError() }
        }
        return ready
    }

    /// Releases the account-level preparation claim when its owner no longer needs it.
    public func releasePrewarm() {
        guard let prewarmLease else { return }
        self.prewarmLease = nil
        release(prewarmLease)
    }

    /// Ends one link's claim; the hub stops ``Configuration/idleGrace`` after the last one.
    public func release(_ lease: Lease) {
        leases.remove(lease)
        scheduleIdleStopIfUnused()
    }

    /// Keeps the hub for the rest of the app session on behalf of a client process the
    /// app cannot watch (the `cmux vm tui` pane), starting it if needed.
    public func pinForExternalClient() async throws -> Ready {
        pinnedByExternalClient = true
        idleStopTask?.cancel()
        idleStopTask = nil
        restartAttempts = 0
        return try await ensureRunning()
    }

    /// Stops the hub on purpose (sign-out, revoke); leases are dropped, no restart follows.
    public func stop() {
        stop(preservingPreparationTask: false)
    }

    private func resetForScopeChange() {
        stop(preservingPreparationTask: true)
    }

    private func stop(preservingPreparationTask: Bool) {
        generation &+= 1
        if !preservingPreparationTask {
            preparationTask?.cancel()
            preparationTask = nil
            preparationScope = nil
            preparationID = nil
        }
        idleStopTask?.cancel()
        idleStopTask = nil
        restartTask?.cancel()
        restartTask = nil
        restartAttempts = 0
        leases.removeAll()
        prewarmLease = nil
        pinnedByExternalClient = false
        activeTeamScope = nil
        if case .starting(_, let task) = state { task.cancel() }
        state = .stopped
        processID = nil
        pendingStartupExit = nil
        processHandle.terminate()
        removeSocketFile()
    }

    /// Kills the hub synchronously from `applicationWillTerminate`, where nothing may await.
    public nonisolated func terminateForAppQuit() {
        processHandle.terminate()
    }

    public func status() -> Status {
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

    private func ensureRunning(
        allowWhenCloudDisabled: Bool = false,
        expectedTeamScope: AuthenticatedTeamScope? = nil
    ) async throws -> Ready {
        switch state {
        case .running(let ready):
            return ready
        case .starting(_, let task):
            return try await task.value
        case .stopped:
            break
        }
        let startGeneration = generation
        let task = Task<Ready, Error> {
            try await self.startWithRecovery(
                generation: startGeneration,
                allowWhenCloudDisabled: allowWhenCloudDisabled,
                expectedTeamScope: expectedTeamScope
            )
        }
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
    private func startWithRecovery(
        generation startGeneration: UInt64,
        allowWhenCloudDisabled: Bool,
        expectedTeamScope: AuthenticatedTeamScope?
    ) async throws -> Ready {
        let delays = Array(configuration.restartBackoff.prefix(3))
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            guard generation == startGeneration else { throw CancellationError() }
            // Each child owns its own startup-exit signal. A late callback from
            // a failed child cannot poison a later recovery attempt because its
            // process identity no longer matches the replacement.
            pendingStartupExit = nil
            do {
                return try await start(
                    generation: startGeneration,
                    allowWhenCloudDisabled: allowWhenCloudDisabled,
                    expectedTeamScope: expectedTeamScope,
                    refreshEnrollment: attempt > 0
                )
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

    private func start(
        generation startGeneration: UInt64,
        allowWhenCloudDisabled: Bool,
        expectedTeamScope: AuthenticatedTeamScope?,
        refreshEnrollment: Bool
    ) async throws -> Ready {
        let enrollment: Enrollment
        if refreshEnrollment {
            // A hub process can reject a previously written config without
            // producing a useful enrollment error. Recovery must replace that
            // state before retrying, otherwise every retry starts the same
            // dead child and the shared socket never becomes ready.
            if allowWhenCloudDisabled, let refresh = configuration.refreshEnrollmentWhenCloudDisabled {
                enrollment = try await refresh(expectedTeamScope)
            } else if let refresh = configuration.refreshEnrollment {
                enrollment = try await refresh()
            } else if allowWhenCloudDisabled, let activationEnrollment = configuration.enrollWhenCloudDisabled {
                enrollment = try await activationEnrollment(expectedTeamScope)
            } else {
                enrollment = try await configuration.enroll()
            }
        } else if allowWhenCloudDisabled, let activationEnrollment = configuration.enrollWhenCloudDisabled {
            enrollment = try await activationEnrollment(expectedTeamScope)
        } else {
            enrollment = try await configuration.enroll()
        }
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
        activeTeamScope = expectedTeamScope
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
public protocol CloudWireGuardHubProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// The exit status once the process has ended.
    var exitStatus: Int32? { get }
    /// The last few lines the process wrote, for error messages.
    var outputTail: String { get }
    func terminate()
    /// Registers the one exit callback; a process that already exited calls it at once.
    func onExit(_ handler: @escaping @Sendable (Int32) -> Void)
}

public protocol CloudWireGuardHubSpawning: Sendable {
    func spawn(executable: URL, arguments: [String]) throws -> any CloudWireGuardHubProcess
}

/// The hub's current child, reachable without actor isolation so app termination can
/// kill it synchronously. The short lock protects only the process-pointer handoff
/// between the hub actor and `applicationWillTerminate`.
final class CloudWireGuardHubProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: (any CloudWireGuardHubProcess)?

    public func replace(with process: any CloudWireGuardHubProcess) {
        lock.lock()
        let previous = self.process
        self.process = process
        lock.unlock()
        previous?.terminate()
    }

    public func terminate() {
        lock.lock()
        let current = process
        process = nil
        lock.unlock()
        current?.terminate()
    }

    public var exitStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return process?.exitStatus
    }
}
