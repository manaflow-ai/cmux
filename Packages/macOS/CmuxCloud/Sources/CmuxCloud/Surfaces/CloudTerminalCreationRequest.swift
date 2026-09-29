import CmuxCloud
import CmuxCloudTui
import CmuxSurfaceCatalogModel
import Foundation

/// Retains one UI intent's daemon identity across explicit retries.
///
/// The first create uses the existing idempotency-key contract. Only a user
/// retry reads the durable receipt, once; no polling or automatic recreation
/// runs behind a pending pane.
@MainActor
public final class CloudTerminalCreationRequest {
    public let id: UUID
    public let commandOverride: [String]?
    public let opensMachine: Bool
    public let suppressWelcome: Bool
    public private(set) var remoteWorkspaceID: String?
    public let correlationKey: String
    public private(set) var attemptKey: String
    private var submitted = false
    private var adoptsDurableAttempt = false
    private var initialWorkspaceRequest: CloudTuiRequest?
    private var initialWorkspaceUnavailable = false
    public private(set) var usesMachineStarter = false
    /// Durable first-workspace results are retained before any cancellation fence.
    public private(set) var initialWorkspaceReceipt: CmuxTuiSnapshotParser.CreatedTerminalPath?
    public private(set) var recordedInitialTerminal: SurfaceResource?

    public init(id: UUID = UUID(), remoteWorkspaceID: String? = nil, commandOverride: [String]? = nil, restoring: Bool = false, opensMachine: Bool = false, suppressWelcome: Bool = false, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.id = id
        self.commandOverride = commandOverride
        self.opensMachine = opensMachine
        self.suppressWelcome = suppressWelcome || environment["CMUX_CLOUD_WELCOME"] == "0"
        self.remoteWorkspaceID = remoteWorkspaceID
        let key = "cmux-cloud-create-\(id.uuidString.lowercased())"
        correlationKey = key
        attemptKey = key
        submitted = restoring
        adoptsDurableAttempt = restoring
    }

    /// Binds the immutable Cloud workspace before the first daemon mutation.
    public func bind(remoteWorkspaceID: String) {
        guard !submitted else { return }
        self.remoteWorkspaceID = remoteWorkspaceID
    }

    /// First attempts omit the additive correlation flag for older daemons.
    /// A new-key retry uses it only after the daemon explicitly authorizes one.
    public var correlationArgument: String? { attemptKey == correlationKey ? nil : correlationKey }

    /// Reserves the daemon-owned first workspace and its initial terminal.
    public func prepareInitialWorkspace(
        using runner: any CloudTuiCommandRunning,
        machineID: String,
        welcomeEligible: Bool
    ) async throws -> CmuxTuiSnapshotParser.CreatedTerminalPath? {
        guard opensMachine, !initialWorkspaceUnavailable else { return nil }
        if initialWorkspaceRequest == nil {
            var fields: [String: Any] = ["machine_id": machineID, "welcome": welcomeEligible && !suppressWelcome]
            if let remoteWorkspaceID { fields["workspace"] = remoteWorkspaceID }
            initialWorkspaceRequest = CloudTuiRequest("cloud-first-workspace", fields, raw: true)
        }
        guard let initialWorkspaceRequest else { return nil }
        let data: Data
        do {
            data = try await runner.runTuiCommand(arguments: initialWorkspaceRequest, deadline: .seconds(30))
        } catch {
            if case .rejected(let reason) = CloudTuiDaemonAnswer(error: error),
               reason.contains("unknown variant") || reason.contains("unknown command") || reason.contains("operation.unsupported") {
                initialWorkspaceUnavailable = true
                return nil
            }
            throw error
        }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["created_path"] != nil else { throw CloudDiagnosticFailure.response }
        if object["occupied"] as? Bool == true { throw CloudDiagnosticFailure.placement }
        if object["created_path"] is NSNull {
            initialWorkspaceUnavailable = true
            return nil
        }
        object["value"] = object["created_path"]
        guard let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: object),
              let workspaceID = created.workspaceID,
              remoteWorkspaceID == nil || remoteWorkspaceID == workspaceID else {
            throw CloudDiagnosticFailure.placement
        }
        usesMachineStarter = true
        initialWorkspaceReceipt = created
        return created
    }

    /// Records the local resource before the lifecycle fence can cancel adoption.
    public func recordInitialTerminal(_ resource: SurfaceResource) {
        recordedInitialTerminal = resource
    }

    /// Returns an existing terminal, or authorizes exactly one mutation attempt.
    public func prepare(
        using runner: any CloudTuiCommandRunning,
        socketPath: String
    ) async throws -> CmuxTuiSnapshotParser.CreatedTerminalPath? {
        try Task.checkCancellation()
        guard submitted else {
            submitted = true
            return nil
        }
        let data: Data
        do {
            data = try await runner.runTuiCommand(
                arguments: CloudTuiRequest("session.creation.resolve", ["correlation_key": correlationKey]),
                deadline: .seconds(30)
            )
        } catch {
            if case .rejected(let reason) = CloudTuiDaemonAnswer(error: error),
               reason.contains("unsupported") || reason.contains("unknown command") {
                throw CloudDiagnosticFailure.unsupported
            }
            throw error
        }
        try Task.checkCancellation()
        if adoptsDurableAttempt {
            // After app restart the daemon's correlation receipt is the only
            // authoritative record of which attempt committed this user intent.
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let envelope = (object?["result"] as? [String: Any]) ?? (object?["data"] as? [String: Any]) ?? object
            let value = (envelope?["value"] as? [String: Any]) ?? envelope
            if value?["correlation_key"] as? String == correlationKey,
               let recorded = value?["idempotency_key"] as? String, !recorded.isEmpty {
                attemptKey = recorded
            }
            adoptsDurableAttempt = false
        }
        guard let resolution = CloudTerminalCreationRetryResolution(
            data: data, correlationKey: correlationKey, attemptKey: attemptKey
        ) else { throw CloudDiagnosticFailure.response }
        switch resolution {
        case .created(let terminal):
            if let remoteWorkspaceID, terminal.workspaceID != remoteWorkspaceID { throw CloudDiagnosticFailure.placement }
            return terminal
        case .sameAttempt:
            return nil
        case .newAttempt:
            attemptKey = "cmux-cloud-create-\(UUID().uuidString.lowercased())"
            return nil
        case .pending:
            throw CloudDiagnosticFailure.timeout
        case .indeterminate:
            throw CloudDiagnosticFailure.response
        }
    }
}
