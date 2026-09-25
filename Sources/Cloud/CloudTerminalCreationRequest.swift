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
final class CloudTerminalCreationRequest {
    let id: UUID
    let commandOverride: [String]?
    let opensMachine: Bool
    let suppressWelcome: Bool
    private(set) var remoteWorkspaceID: String?
    let correlationKey: String
    private(set) var attemptKey: String
    private var submitted = false
    private var adoptsDurableAttempt = false
    private var initialWorkspaceRequest: CloudTuiRequest?
    private var initialWorkspaceUnavailable = false
    private(set) var usesMachineStarter = false

    init(id: UUID = UUID(), remoteWorkspaceID: String? = nil, commandOverride: [String]? = nil, restoring: Bool = false, opensMachine: Bool = false, suppressWelcome: Bool = false) {
        self.id = id
        self.commandOverride = commandOverride
        self.opensMachine = opensMachine
        self.suppressWelcome = suppressWelcome
        self.remoteWorkspaceID = remoteWorkspaceID
        let key = "cmux-cloud-create-\(id.uuidString.lowercased())"
        correlationKey = key
        attemptKey = key
        submitted = restoring
        adoptsDurableAttempt = restoring
    }

    /// Binds the immutable Cloud workspace before the first daemon mutation.
    func bind(remoteWorkspaceID: String) {
        guard !submitted else { return }
        self.remoteWorkspaceID = remoteWorkspaceID
    }

    /// First attempts omit the additive correlation flag for older daemons.
    /// A new-key retry uses it only after the daemon explicitly authorizes one.
    var correlationArgument: String? { attemptKey == correlationKey ? nil : correlationKey }

    /// Only an interactive machine open may start the daemon's reserved first shell.
    /// Lost replies retry the same native reservation; a rejected older command
    /// falls back before any terminal has been created by this request.
    func prepareInitialWorkspace(
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
        try Task.checkCancellation()
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
        return created
    }

    /// Returns an existing terminal, or authorizes exactly one mutation attempt.
    func prepare(
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
