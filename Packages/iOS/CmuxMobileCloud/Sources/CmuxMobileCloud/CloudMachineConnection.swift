public import Foundation
public import Observation
import OSLog

private let cloudLinkLog = Logger(subsystem: "dev.cmux.ios", category: "cloud-link")

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
    private var listTask: Task<Void, Never>?
    private var closed = false

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
                async let terminalRows = session.listTerminals()
                async let workspaceRows = session.listWorkspaces()
                let (rows, workspaceRowsValue) = try await (terminalRows, workspaceRows)
                guard !Task.isCancelled else { return }
                self.terminals = .loaded(rows)
                self.workspaces = .loaded(workspaceRowsValue)
                self.lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.terminals = .failed(CloudSessionFailure.classify(error, stage: .link), previous: self.terminals.elements)
                self.workspaces = .failed(CloudSessionFailure.classify(error, stage: .link), previous: self.workspaces.elements)
            }
        }
    }

    /// Create a remote workspace with a starter terminal.
    @discardableResult
    public func createWorkspace(name: String? = nil) async -> String? {
        isCreatingWorkspace = true
        defer { isCreatingWorkspace = false }
        do {
            let id = try await connectedSession().createWorkspace(name: name)
            lastError = nil
            refreshTerminals()
            return id
        } catch {
            lastError = CloudSessionFailure.classify(error, stage: .link)
            return nil
        }
    }

    /// Create a terminal and return its id, refreshing the catalog.
    @discardableResult
    public func createTerminal(name: String? = nil) async -> String? {
        isCreatingTerminal = true
        defer { isCreatingTerminal = false }
        do {
            let session = try await connectedSession()
            let id = try await session.createTerminal(name: name)
            lastError = nil
            refreshTerminals()
            return id
        } catch {
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
        let session = try await connectedSession()
        try await session.attach(terminalID: terminalID, output: output)
        lastError = nil
        return CloudTerminalAttachment(session: session, terminalID: terminalID)
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
        let session = try await connectedSession()
        async let workspaceRows = session.listWorkspaces()
        async let terminalRows = session.listTerminals()
        return try await (workspaceRows, terminalRows)
    }

    /// Close the link.
    public func close() {
        closed = true
        listTask?.cancel()
        listTask = nil
        connectTask?.cancel()
        connectTask = nil
        session?.disconnect()
        session = nil
    }

    private func connectedSession() async throws -> any CloudTerminalSession {
        if let session { return session }
        if let connectTask { return try await connectTask.value }
        let task = Task<any CloudTerminalSession, any Error> { [service, connector, tunnel, identity, stateDirectory, deviceName, approvalClock, machine] in
            let endpoint = try await service.openAttach(machineID: machine.id, deviceFingerprint: identity.fingerprint)
            cloudLinkLog.info("Cloud link started trustedCarrier=\(endpoint.trustedCarrier, privacy: .public) invitation=\(endpoint.invitation != nil, privacy: .public)")
            var approval: Task<Void, Never>?
            if !endpoint.trustedCarrier, let invitation = endpoint.invitation {
                approval = Task {
                    await Self.approveUntilGranted(
                        service: service,
                        machineID: machine.id,
                        invitationId: invitation.invitationId,
                        clock: approvalClock
                    )
                }
            }
            defer { approval?.cancel() }
            return try await connector.connect(
                route: endpoint.route,
                stateDirectory: stateDirectory,
                deviceName: deviceName,
                invitation: endpoint.trustedCarrier ? nil : endpoint.invitation?.uri,
                trustedCarrier: endpoint.trustedCarrier,
                tunnel: tunnel
            )
        }
        connectTask = task
        defer { connectTask = nil }
        do {
            let session = try await task.value
            if closed {
                session.disconnect()
                throw CancellationError()
            }
            self.session = session
            return session
        } catch {
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
        clock: any Clock<Duration>
    ) async {
        for _ in 0 ..< 150 {
            guard !Task.isCancelled else { return }
            do {
                try await clock.sleep(for: .seconds(2))
            } catch {
                return
            }
            do {
                if try await service.approveEnrollment(machineID: machineID, invitationId: invitationId) {
                    return
                }
            } catch let error as CloudAPIError {
                if case .httpStatus(404, _, _) = error { return }
            } catch {
                continue
            }
        }
    }
}
