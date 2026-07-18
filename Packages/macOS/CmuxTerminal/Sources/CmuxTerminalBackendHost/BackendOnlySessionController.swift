public import CmuxTerminalBackend
public import CmuxTerminalBackendService
internal import Darwin
public import Foundation

public enum BackendOnlyHostConnectionError: Error, Equatable, Sendable {
    case invalidBundleIdentifier
    case invalidClientIdentity
    case disabled
    case approvalRequired
    case missingBundleItem
    case serviceNotFound
    case backendUnavailable
    case readOnly
}

/// One readiness-fenced canonical connection used by the lightweight Swift host.
public struct BackendOnlyHostConnection: Sendable {
    public let session: BackendCanonicalSession
    public let readiness: BackendServiceReadiness
    public let initialSnapshot: TopologySnapshot

    public init(
        session: BackendCanonicalSession,
        readiness: BackendServiceReadiness,
        initialSnapshot: TopologySnapshot
    ) {
        self.session = session
        self.readiness = readiness
        self.initialSnapshot = initialSnapshot
    }
}

/// Connection lifecycle seam used by the host model and its process-free tests.
protocol BackendOnlyHostSessionControlling: Sendable {
    func connect() async throws -> BackendOnlyHostConnection

    func claimProjectionState(
        for connection: BackendOnlyHostConnection,
        logicalPresentationID: UUID
    ) async throws -> BackendProjectionState

    func events(
        for connection: BackendOnlyHostConnection
    ) async -> AsyncStream<BackendCanonicalSessionEvent>

    func currentSnapshot(
        for connection: BackendOnlyHostConnection
    ) async -> TopologySnapshot?

    func invalidate(_ connection: BackendOnlyHostConnection) async
}

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

    public init?(
        bundleURL: URL,
        bundleIdentifier: String?,
        userID: UInt32? = nil,
        homeDirectoryURL: URL? = nil,
        processInstanceUUID: UUID? = nil
    ) {
        let userID = userID ?? UInt32(Darwin.geteuid())
        let homeDirectoryURL = homeDirectoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
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

    func claimProjectionState(
        for connection: BackendOnlyHostConnection,
        logicalPresentationID: UUID
    ) async throws -> BackendProjectionState {
        try await connection.session.claimProjectionState(
            logicalPresentationID: logicalPresentationID
        )
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
            case .ready(let value):
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
                initialSnapshot: snapshot
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
