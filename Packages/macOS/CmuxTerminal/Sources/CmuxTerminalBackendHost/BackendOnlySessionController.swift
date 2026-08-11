public import CmuxTerminalBackend
public import CmuxTerminalBackendService
public import Foundation
internal import Darwin

/// Registers the bundled cmux-tui service and opens one credential-fenced session.
///
/// The app process never starts a PTY or terminal parser. ServiceManagement owns
/// daemon activation, and the canonical session binds its second socket to the
/// exact audit-token identity that passed the readiness probe.
public actor BackendOnlySessionController: BackendOnlyHostSessionControlling {
    private let descriptor: BackendServiceDescriptor
    private let runtimePaths: BackendServiceRuntimePaths
    private let bootstrap: BackendServiceBootstrapCoordinator
    private let processInstanceUUID: UUID
    private var connection: BackendOnlyHostConnection?
    private var connectionTask: Task<BackendOnlyHostConnection, any Error>?
    private var connectionAttemptID: UUID?

    /// Creates a controller for one explicit user runtime directory.
    public init?(
        bundleURL: URL,
        bundleIdentifier: String?,
        userID: UInt32? = nil,
        homeDirectoryURL: URL,
        processInstanceUUID: UUID? = nil
    ) {
        let userID = userID ?? UInt32(Darwin.geteuid())
        let processInstanceUUID = processInstanceUUID ?? UUID()
        guard let bundleIdentifier,
              let descriptor = BackendServiceDescriptor(bundleIdentifier: bundleIdentifier)
        else { return nil }
        let runtimePaths = BackendServiceRuntimePaths(
            descriptor: descriptor,
            userID: userID,
            homeDirectoryURL: homeDirectoryURL
        )
        let inspection = BackendServiceBundleInspection(
            bundleURL: bundleURL,
            descriptor: descriptor
        )
        let registration = SystemBackendServiceRegistration(
            descriptor: descriptor,
            bundleInspection: inspection,
            runtimePaths: runtimePaths,
            userID: userID
        )
        let readiness = BackendServiceReadinessProbe(
            descriptor: descriptor,
            runtimePaths: runtimePaths,
            expectedUserID: userID
        )
        self.descriptor = descriptor
        self.runtimePaths = runtimePaths
        self.processInstanceUUID = processInstanceUUID
        bootstrap = BackendServiceBootstrapCoordinator(
            activationPolicy: BackendServiceActivationPolicy(buildSettingValue: "YES"),
            inspection: inspection,
            registration: registration,
            readinessChecker: readiness,
            handoffCoordinator: BackendServiceHandoffCoordinator(
                descriptor: descriptor,
                runtimePaths: runtimePaths,
                registration: registration,
                readinessChecker: readiness,
                processInstanceUUID: processInstanceUUID,
                userID: userID
            )
        )
    }

    /// Connects to one readiness-fenced canonical backend session.
    public func connect() async throws -> BackendOnlyHostConnection {
        if let cached = connection {
            let snapshot = await cached.session.currentSnapshot()
            guard connection?.session === cached.session else {
                return try await connect()
            }
            if snapshot != nil {
                return cached
            }
            connection = nil
            await cached.session.close()
        }

        if let connectionTask {
            return try await connectionTask.value
        }

        let attemptID = UUID()
        connectionAttemptID = attemptID
        let task = Task {
            try await establishConnection(attemptID: attemptID)
        }
        connectionTask = task
        return try await task.value
    }

    func projectionRPC(
        for connection: BackendOnlyHostConnection
    ) async throws -> any BackendOnlyProjectionDriverRPC {
        connection.session
    }

    func events(
        for connection: BackendOnlyHostConnection
    ) async -> AsyncStream<BackendCanonicalSessionEvent> {
        await connection.session.events()
    }

    func currentSnapshot(
        for connection: BackendOnlyHostConnection
    ) async -> TopologySnapshot? {
        await connection.session.currentSnapshot()
    }

    func invalidate(_ stale: BackendOnlyHostConnection) async {
        if connection?.session === stale.session {
            connection = nil
        }
        await stale.session.close()
    }

    /// Closes the current frontend connection without terminating backend PTYs.
    public func closeFrontendConnection() async {
        let task = connectionTask
        connectionTask = nil
        connectionAttemptID = nil
        task?.cancel()

        let current = connection
        connection = nil
        if let current {
            await current.session.close()
        }
        if let task {
            _ = await task.result
        }
    }

    private func establishConnection(
        attemptID: UUID
    ) async throws -> BackendOnlyHostConnection {
        var openedSession: BackendCanonicalSession?
        do {
            try Task.checkCancellation()
            let result = try await bootstrap.ensureRegistered()
            try Task.checkCancellation()
            let readiness: BackendServiceReadiness
            switch result {
            case let .ready(value):
                readiness = value
            case .disabled:
                throw BackendOnlyHostConnectionError.disabled
            case .requiresApproval:
                throw BackendOnlyHostConnectionError.approvalRequired
            case .missingBundleItem:
                throw BackendOnlyHostConnectionError.missingBundleItem
            case .serviceNotFound:
                throw BackendOnlyHostConnectionError.serviceNotFound
            case .backendUnavailable:
                throw BackendOnlyHostConnectionError.backendUnavailable
            }
            guard readiness.compatibility.readOnlyDiagnostic == nil else {
                throw BackendOnlyHostConnectionError.readOnly
            }
            guard let registrationIdentity = BackendClientRegistrationIdentity(
                clientUUID: descriptor.terminalClientUUID,
                processInstanceUUID: processInstanceUUID
            ) else {
                throw BackendOnlyHostConnectionError.invalidClientIdentity
            }

            let transport = UnixBackendTransport(path: runtimePaths.socketURL.path)
            let session = BackendCanonicalSession(
                transport: transport,
                expectation: BackendCanonicalSessionExpectation(
                    session: readiness.session,
                    authority: readiness.authority,
                    processID: readiness.processID,
                    peerIdentity: readiness.peerIdentity
                ),
                registrationIdentity: registrationIdentity
            )
            openedSession = session
            guard let snapshot = try await session.connect() else {
                throw BackendOnlyHostConnectionError.readOnly
            }
            try Task.checkCancellation()
            guard connectionAttemptID == attemptID else {
                throw CancellationError()
            }
            let connected = BackendOnlyHostConnection(
                session: session,
                readiness: readiness,
                initialSnapshot: snapshot,
                stableClientID: registrationIdentity.clientUUID,
                processInstanceID: registrationIdentity.processInstanceUUID
            )
            connection = connected
            clearConnectionAttempt(attemptID)
            return connected
        } catch {
            if let openedSession {
                await openedSession.close()
            }
            clearConnectionAttempt(attemptID)
            throw error
        }
    }

    private func clearConnectionAttempt(_ attemptID: UUID) {
        guard connectionAttemptID == attemptID else { return }
        connectionAttemptID = nil
        connectionTask = nil
    }
}
