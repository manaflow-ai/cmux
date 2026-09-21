import Foundation

/// Retains one UI intent's daemon identity across explicit retries.
///
/// The first create uses the existing idempotency-key contract. Only a user
/// retry reads the durable receipt, once; no polling or automatic recreation
/// runs behind a pending pane.
@MainActor
final class CloudTerminalCreationRequest {
    let id: UUID
    private(set) var remoteWorkspaceID: String?
    let correlationKey: String
    private(set) var attemptKey: String
    private var submitted = false

    init(id: UUID = UUID(), remoteWorkspaceID: String? = nil) {
        self.id = id
        self.remoteWorkspaceID = remoteWorkspaceID
        let key = "cmux-cloud-create-\(id.uuidString.lowercased())"
        correlationKey = key
        attemptKey = key
    }

    /// Binds the immutable Cloud workspace before the first daemon mutation.
    func bind(remoteWorkspaceID: String) {
        guard !submitted else { return }
        self.remoteWorkspaceID = remoteWorkspaceID
    }

    /// First attempts omit the additive correlation flag for older daemons.
    /// A new-key retry uses it only after the daemon explicitly authorizes one.
    var correlationArgument: String? { attemptKey == correlationKey ? nil : correlationKey }

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
