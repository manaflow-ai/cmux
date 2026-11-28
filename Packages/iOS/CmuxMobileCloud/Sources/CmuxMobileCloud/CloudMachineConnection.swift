public import Foundation
public import Observation
import OSLog

private let cloudLinkLog = Logger(subsystem: "dev.cmux.ios", category: "cloud-link")

private enum CloudMachineConnectionError: Error, Sendable, CustomStringConvertible {
    case invitationExpired
    case approvalTimedOut

    var description: String {
        switch self {
        case .invitationExpired: "cloud invitation expired"
        case .approvalTimedOut: "cloud invitation approval timed out"
        }
    }
}

private actor CloudConnectionCancellation {
    private var cancelled = false
    private var connector: Task<any CloudTerminalSession, any Error>?
    private var approval: Task<Void, any Error>?

    func set(
        connector: Task<any CloudTerminalSession, any Error>,
        approval: Task<Void, any Error>
    ) {
        guard !cancelled else {
            connector.cancel()
            approval.cancel()
            return
        }
        self.connector = connector
        self.approval = approval
    }

    func cancel() {
        cancelled = true
        connector?.cancel()
        approval?.cancel()
    }
}

private actor CloudConnectionHandshake {
    private let continuation: AsyncThrowingStream<any CloudTerminalSession, any Error>.Continuation
    private var session: (any CloudTerminalSession)?
    private var approvalGranted = false
    private var finished = false

    init(continuation: AsyncThrowingStream<any CloudTerminalSession, any Error>.Continuation) {
        self.continuation = continuation
    }

    func sessionConnected(_ session: any CloudTerminalSession) {
        guard !finished else {
            session.disconnect()
            return
        }
        if self.session != nil {
            session.disconnect()
            return
        }
        self.session = session
        finishIfReady()
    }

    func approvalSucceeded() {
        guard !finished else { return }
        approvalGranted = true
        finishIfReady()
    }

    func fail(_ error: any Error) {
        guard !finished else { return }
        finished = true
        session?.disconnect()
        session = nil
        continuation.finish(throwing: error)
    }

    private func finishIfReady() {
        guard !finished, approvalGranted, let session else { return }
        finished = true
        self.session = nil
        if case .terminated = continuation.yield(session) {
            session.disconnect()
        }
        continuation.finish()
    }
}

private actor CloudConnectionInFlight {
    typealias Session = any CloudTerminalSession

    struct Lease: Sendable {
        let id: UUID
        let session: Session
    }

    private let task: Task<Session, any Error>
    private var result: Result<Session, any Error>?
    private var successfulSession: Session?
    private var waiters: [UUID: CheckedContinuation<Lease, any Error>] = [:]
    private var deliveredWaiters: Set<UUID> = []
    private var activeClaims = 0
    private var sessionDisconnected = false
    private var cancelled = false
    private var isMonitoring = false

    init(task: Task<Session, any Error>) {
        self.task = task
    }

    func wait() async throws -> Lease {
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    switch result {
                    case .success(let session):
                        deliveredWaiters.insert(id)
                        continuation.resume(returning: Lease(id: id, session: session))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                } else if Task.isCancelled || cancelled || task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    startMonitoringIfNeeded()
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
    }

    func finish(_ result: Result<Session, any Error>) {
        guard self.result == nil else {
            if case .success(let session) = result {
                session.disconnect()
            }
            return
        }
        guard !cancelled, !waiters.isEmpty else {
            if case .success(let session) = result {
                session.disconnect()
            }
            self.result = .failure(CancellationError())
            return
        }
        self.result = result
        let currentWaiters = waiters
        waiters.removeAll()
        switch result {
        case .success(let session):
            successfulSession = session
            deliveredWaiters.formUnion(currentWaiters.keys)
            for (id, waiter) in currentWaiters {
                waiter.resume(returning: Lease(id: id, session: session))
            }
        case .failure(let error):
            for waiter in currentWaiters.values {
                waiter.resume(throwing: error)
            }
        }
    }

    func cancelAll() {
        cancelled = true
        task.cancel()
        let currentWaiters = Array(waiters.values)
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume(throwing: CancellationError())
        }
        deliveredWaiters.removeAll()
        if activeClaims == 0 {
            releaseUnclaimedSessionIfNeeded()
        }
    }

    func claim(_ lease: Lease) -> Bool {
        guard deliveredWaiters.remove(lease.id) != nil else { return false }
        activeClaims += 1
        return true
    }

    func abandon(_ lease: Lease) {
        guard deliveredWaiters.remove(lease.id) != nil else { return }
        releaseUnclaimedSessionIfNeeded()
    }

    func abandonClaim() {
        guard activeClaims > 0 else { return }
        activeClaims -= 1
        releaseUnclaimedSessionIfNeeded()
    }

    func hasWaiters() -> Bool {
        !waiters.isEmpty || !deliveredWaiters.isEmpty || activeClaims > 0
    }

    func wasCancelled() -> Bool {
        cancelled
    }

    private func startMonitoringIfNeeded() {
        guard !isMonitoring else { return }
        isMonitoring = true
        let task = self.task
        Task { [weak self] in
            do {
                let session = try await task.value
                await self?.finish(.success(session))
            } catch {
                await self?.finish(.failure(error))
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(throwing: CancellationError())
            if waiters.isEmpty {
                cancelled = true
                task.cancel()
            }
            return
        }
        guard deliveredWaiters.remove(id) != nil else { return }
        releaseUnclaimedSessionIfNeeded()
    }

    private func releaseUnclaimedSessionIfNeeded() {
        guard activeClaims == 0,
              deliveredWaiters.isEmpty,
              !sessionDisconnected,
              let successfulSession else { return }
        sessionDisconnected = true
        successfulSession.disconnect()
    }
}

/// One machine's daemon link and terminal catalog.
///
/// The link opens lazily on the first catalog load. First contact hands the
/// daemon an invitation while the control plane's approval is polled
/// alongside, exactly as the Mac does.
@MainActor
@Observable
public final class CloudMachineConnection {
    /// The machine this connection serves.
    public let machine: CloudMachine
    /// The catalog.
    public private(set) var terminals: CloudListPhase<CloudTerminalSummary> = .idle
    /// The daemon's remote workspaces.
    public private(set) var workspaces: CloudListPhase<CloudWorkspaceSummary> = .idle
    /// Whether a remote workspace is being created.
    public private(set) var isCreatingWorkspace = false
    /// Whether a terminal is being created.
    public private(set) var isCreatingTerminal = false
    /// The most recent create/attach error, cleared on the next success.
    public private(set) var lastError: CloudSessionFailure?

    private let service: any CloudVMServing
    private let connector: any CloudTerminalConnecting
    private let tunnel: any CloudTunnel
    private let identity: CloudDeviceIdentity
    private let stateDirectory: URL
    private let deviceName: String
    private let approvalClock: any Clock<Duration>

    private var session: (any CloudTerminalSession)?
    private var connectTask: Task<any CloudTerminalSession, any Error>?
    private var connectionInFlight: CloudConnectionInFlight?
    private var listTask: Task<Void, Never>?
    private var closed = false
    private var operationGeneration: UInt64 = 0
    private let attachmentGate = CloudOperationGate()

    init(
        machine: CloudMachine,
        service: any CloudVMServing,
        connector: any CloudTerminalConnecting,
        tunnel: any CloudTunnel,
        identity: CloudDeviceIdentity,
        stateDirectory: URL,
        deviceName: String,
        approvalClock: any Clock<Duration>
    ) {
        self.machine = machine
        self.service = service
        self.connector = connector
        self.tunnel = tunnel
        self.identity = identity
        self.stateDirectory = stateDirectory
        self.deviceName = deviceName
        self.approvalClock = approvalClock
    }

    /// Load (or reload) the terminal catalog, connecting first if needed.
    public func refreshTerminals() {
        listTask?.cancel()
        terminals = .loading(previous: terminals.elements)
        listTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await connectedSession()
                let catalog = try await session.loadCatalog()
                guard !Task.isCancelled else { return }
                self.terminals = .loaded(catalog.terminals)
                self.workspaces = .loaded(catalog.workspaces)
                self.lastError = nil
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                let failure = CloudSessionFailure.classify(error, stage: .link)
                self.terminals = .failed(failure, previous: self.terminals.elements)
                self.workspaces = .failed(failure, previous: self.workspaces.elements)
                self.lastError = failure
            }
        }
    }

    /// Create a remote workspace with a starter terminal.
    @discardableResult
    public func createWorkspace(name: String? = nil) async -> String? {
        guard !isCreatingWorkspace else { return nil }
        let generation = operationGeneration
        isCreatingWorkspace = true
        defer { isCreatingWorkspace = false }
        do {
            let session = try await currentSession(for: generation)
            let id = try await session.createWorkspace(name: name)
            guard isCurrentOperation(generation), !Task.isCancelled else { return nil }
            lastError = nil
            refreshTerminals()
            return id
        } catch is CancellationError {
            return nil
        } catch {
            guard isCurrentOperation(generation) else { return nil }
            lastError = CloudSessionFailure.classify(error, stage: .link)
            return nil
        }
    }

    /// Create a terminal and return its id, refreshing the catalog.
    @discardableResult
    public func createTerminal(name: String? = nil) async -> String? {
        guard !isCreatingTerminal else { return nil }
        let generation = operationGeneration
        isCreatingTerminal = true
        defer { isCreatingTerminal = false }
        do {
            let session = try await currentSession(for: generation)
            let id = try await session.createTerminal(name: name)
            guard isCurrentOperation(generation), !Task.isCancelled else { return nil }
            lastError = nil
            refreshTerminals()
            return id
        } catch is CancellationError {
            return nil
        } catch {
            guard isCurrentOperation(generation) else { return nil }
            lastError = CloudSessionFailure.classify(error, stage: .link)
            return nil
        }
    }

    /// Create a terminal inside `workspaceID` and return its id, refreshing
    /// the catalog.
    @discardableResult
    public func createTerminal(inWorkspace workspaceID: String, name: String? = nil) async -> String? {
        guard !isCreatingTerminal else { return nil }
        let generation = operationGeneration
        isCreatingTerminal = true
        defer { isCreatingTerminal = false }
        do {
            let session = try await currentSession(for: generation)
            let id = try await session.createTerminal(inWorkspace: workspaceID, name: name)
            guard isCurrentOperation(generation), !Task.isCancelled else { return nil }
            lastError = nil
            refreshTerminals()
            return id
        } catch is CancellationError {
            return nil
        } catch {
            guard isCurrentOperation(generation) else { return nil }
            lastError = CloudSessionFailure.classify(error, stage: .link)
            return nil
        }
    }

    /// Attach to `terminalID`, streaming events to `output` until the
    /// returned attachment is detached.
    public func attach(
        terminalID: String,
        output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void
    ) async throws -> CloudTerminalAttachment {
        let generation = operationGeneration
        let operation = attachmentGate.startLeased { [weak self] makeHold in
            guard let self else { throw CancellationError() }
            return try await self.performAttach(
                terminalID: terminalID,
                output: output,
                generation: generation,
                makeHold: makeHold
            )
        }
        return try await withTaskCancellationHandler(operation: {
            try await operation.result.value
        }, onCancel: {
            Task { @MainActor in operation.cancel() }
        })
    }

    /// Reads the daemon's workspaces and terminals in one pass, connecting
    /// first if needed.
    ///
    /// The observable ``terminals``/``workspaces`` properties drive the Cloud
    /// tab's own screens; this returns the same catalog directly, for a caller
    /// that publishes it somewhere else and needs the failure rather than a
    /// rendered error state.
    public func loadCatalog() async throws -> (
        workspaces: [CloudWorkspaceSummary],
        terminals: [CloudTerminalSummary]
    ) {
        do {
            let session = try await connectedSession()
            let catalog = try await session.loadCatalog()
            lastError = nil
            return catalog
        } catch {
            if !(error is CancellationError) {
                lastError = CloudSessionFailure.classify(error, stage: .link)
            }
            throw error
        }
    }

    /// Close the link.
    public func close() {
        closed = true
        operationGeneration &+= 1
        listTask?.cancel()
        listTask = nil
        connectTask?.cancel()
        connectTask = nil
        if let connectionInFlight {
            Task { await connectionInFlight.cancelAll() }
        }
        connectionInFlight = nil
        session?.disconnect()
        session = nil
    }

    private func isCurrentOperation(_ generation: UInt64) -> Bool {
        !closed && operationGeneration == generation
    }

    private func currentSession(for generation: UInt64) async throws -> any CloudTerminalSession {
        try Task.checkCancellation()
        let session = try await connectedSession()
        try Task.checkCancellation()
        guard isCurrentOperation(generation) else { throw CancellationError() }
        return session
    }

    private func performAttach(
        terminalID: String,
        output: @escaping @Sendable (CloudTerminalOutputEvent) -> Void,
        generation: UInt64,
        makeHold: @MainActor @Sendable () -> CloudOperationGate.Hold
    ) async throws -> CloudTerminalAttachment {
        do {
            let session = try await connectedSession()
            guard isCurrentOperation(generation) else { throw CancellationError() }
            try Task.checkCancellation()
            try await session.attach(terminalID: terminalID, output: output)
            guard isCurrentOperation(generation), !Task.isCancelled else {
                // The operation gate keeps the next attach behind this native
                // call, so this session still owns the single attachment slot.
                session.detach()
                throw CancellationError()
            }
            lastError = nil
            return CloudTerminalAttachment(
                session: session,
                terminalID: terminalID,
                lifetime: makeHold()
            )
        } catch {
            if !(error is CancellationError) {
                lastError = CloudSessionFailure.classify(error, stage: .link)
            }
            throw error
        }
    }

    private func connectedSession() async throws -> any CloudTerminalSession {
        guard !closed else { throw CancellationError() }
        if let session { return session }
        if connectTask?.isCancelled == true {
            connectTask = nil
            connectionInFlight = nil
        }
        if let connectionInFlight {
            do {
                let lease = try await connectionInFlight.wait()
                guard !closed, !Task.isCancelled else {
                    await connectionInFlight.abandon(lease)
                    throw CancellationError()
                }
                guard await connectionInFlight.claim(lease) else {
                    throw CancellationError()
                }
                guard !closed, !Task.isCancelled else {
                    await connectionInFlight.abandonClaim()
                    throw CancellationError()
                }
                let session = lease.session
                self.session = session
                connectTask = nil
                self.connectionInFlight = nil
                return session
            } catch {
                if await connectionInFlight.wasCancelled() {
                    if self.connectionInFlight === connectionInFlight {
                        connectTask = nil
                        self.connectionInFlight = nil
                    }
                    guard !closed, !Task.isCancelled else { throw error }
                    return try await connectedSession()
                }
                if !(await connectionInFlight.hasWaiters()) {
                    connectTask = nil
                    self.connectionInFlight = nil
                }
                throw error
            }
        }
        let task = Task<any CloudTerminalSession, any Error> { [service, connector, tunnel, identity, stateDirectory, deviceName, approvalClock, machine] in
            let endpoint = try await service.openAttach(machineID: machine.id, deviceFingerprint: identity.fingerprint)
            cloudLinkLog.notice("Cloud link started trustedCarrier=\(endpoint.trustedCarrier, privacy: .public) invitation=\(endpoint.invitation != nil, privacy: .public)")
            // Approval failure must not wait for a blocking native connect.
            // A session returned after the stream ends is closed immediately.
            let cancellation = CloudConnectionCancellation()
            let sessions = AsyncThrowingStream<any CloudTerminalSession, any Error> { continuation in
                let handshake = CloudConnectionHandshake(continuation: continuation)
                let connectorTask = Task<any CloudTerminalSession, any Error> {
                    do {
                        let session = try await connector.connect(
                            route: endpoint.route,
                            stateDirectory: stateDirectory,
                            deviceName: deviceName,
                            invitation: endpoint.trustedCarrier ? nil : endpoint.invitation?.uri,
                            trustedCarrier: endpoint.trustedCarrier,
                            tunnel: tunnel
                        )
                        await handshake.sessionConnected(session)
                        return session
                    } catch {
                        await handshake.fail(error)
                        throw error
                    }
                }
                let approvalTask = Task<Void, any Error> {
                    do {
                        if !endpoint.trustedCarrier, let invitation = endpoint.invitation {
                            try await Self.approveUntilGranted(
                                service: service,
                                machineID: machine.id,
                                invitationId: invitation.invitationId,
                                clock: approvalClock
                            )
                        }
                        await handshake.approvalSucceeded()
                    } catch {
                        await handshake.fail(error)
                    }
                }
                Task {
                    await cancellation.set(connector: connectorTask, approval: approvalTask)
                }
                continuation.onTermination = { _ in
                    Task { await cancellation.cancel() }
                }
            }
            return try await withTaskCancellationHandler(operation: {
                for try await session in sessions {
                    guard !Task.isCancelled else {
                        session.disconnect()
                        throw CancellationError()
                    }
                    return session
                }
                throw CancellationError()
            }, onCancel: {
                Task { await cancellation.cancel() }
            })
        }
        connectTask = task
        let connectionInFlight = CloudConnectionInFlight(task: task)
        self.connectionInFlight = connectionInFlight
        do {
            let lease = try await connectionInFlight.wait()
            guard !closed, !Task.isCancelled else {
                await connectionInFlight.abandon(lease)
                throw CancellationError()
            }
            guard await connectionInFlight.claim(lease) else {
                throw CancellationError()
            }
            guard !closed, !Task.isCancelled else {
                await connectionInFlight.abandonClaim()
                throw CancellationError()
            }
            let session = lease.session
            self.session = session
            connectTask = nil
            self.connectionInFlight = nil
            return session
        } catch {
            if !(await connectionInFlight.hasWaiters()) {
                connectTask = nil
                self.connectionInFlight = nil
            }
            throw error
        }
    }

    /// Same loop as the Mac: the control plane minted the invitation for the
    /// signed-in user, so approving encodes "already authenticated". Polls
    /// every two seconds for up to five minutes or until cancelled.
    static func approveUntilGranted(
        service: any CloudVMServing,
        machineID: String,
        invitationId: String,
        clock: any Clock<Duration>,
        attemptLimit: Int = 150,
        timeout: Duration = .seconds(5 * 60)
    ) async throws {
        let pollingTask = Task<Void, any Error> {
            try await Self.pollForApproval(
                service: service,
                machineID: machineID,
                invitationId: invitationId,
                clock: clock,
                attemptLimit: attemptLimit
            )
        }
        do {
            _ = try await CloudSystemVPNTaskTimeout(timeout: timeout).value(pollingTask)
        } catch is CloudSystemVPNTaskTimeout.Failure {
            throw CloudMachineConnectionError.approvalTimedOut
        }
    }

    private static func pollForApproval(
        service: any CloudVMServing,
        machineID: String,
        invitationId: String,
        clock: any Clock<Duration>,
        attemptLimit: Int
    ) async throws {
        for _ in 0 ..< max(1, attemptLimit) {
            try Task.checkCancellation()
            try await clock.sleep(for: .seconds(2))
            do {
                if try await service.approveEnrollment(machineID: machineID, invitationId: invitationId) {
                    return
                }
            } catch let error as CloudAPIError {
                if case .httpStatus(404, _, _) = error {
                    throw CloudMachineConnectionError.invitationExpired
                }
                if !CloudSessionFailure.classify(error, stage: .link).isRetryable {
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw CloudMachineConnectionError.approvalTimedOut
    }
}
