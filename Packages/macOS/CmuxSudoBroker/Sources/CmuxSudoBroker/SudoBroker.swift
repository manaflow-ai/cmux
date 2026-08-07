import Foundation

/// Owns sudo request discovery and user decision transitions.
public actor SudoBroker {
    private let store: SudoSpoolStore
    private let dependencies: SudoBrokerDependencies
    private let messages: SudoFailureMessages
    private var records: [String: SudoPendingRequest] = [:]

    init(
        paths: SudoBrokerPaths,
        dependencies: SudoBrokerDependencies,
        messages: SudoFailureMessages,
        fileManager: FileManager = .default
    ) {
        store = SudoSpoolStore(paths: paths, fileManager: fileManager)
        self.dependencies = dependencies
        self.messages = messages
    }

    /// Creates the private spool and discovers requests available for review.
    ///
    /// - Returns: Newly discovered request snapshots.
    public func start() async throws -> [SudoPendingRequest] {
        try store.ensureDirectories()
        let pending = store.pendingRequests()
        for item in pending {
            records[item.request.id] = item
        }
        return pending
    }

    /// Returns the currently reviewable request snapshots.
    public func pendingRequests() -> [SudoPendingRequest] {
        records.values.sorted { $0.request.id < $1.request.id }
    }

    /// Approves the exact captured script and hands it to the execution runner.
    ///
    /// - Parameter id: The request identifier selected by the user.
    public func approve(id: String) async {
        guard let pending = records[id] else { return }
        let now = await dependencies.clock.now()
        do {
            // Legacy behavior launches first and assumes sudo will fail fast if
            // Touch ID is unavailable.
            try store.stageApprovedScript(pending.script, id: id)
            try store.writeState(
                SudoRequestState(id: id, phase: .approved, updatedAt: now)
            )
            let launched = try await dependencies.runner.launch(
                requestID: id,
                paths: store.paths
            )
            try store.writeState(
                SudoRequestState(
                    id: id,
                    phase: .executing,
                    updatedAt: now,
                    runner: launched.identity
                )
            )
        } catch {
            _ = try? store.writeResultIfAbsent(
                SudoResult(
                    id: id,
                    status: .failed,
                    errorCode: .runnerLaunchFailed,
                    note: error.localizedDescription
                )
            )
            records.removeValue(forKey: id)
        }
    }

    /// Denies a request without executing its script.
    ///
    /// - Parameter id: The request identifier selected by the user.
    public func deny(id: String) {
        guard records.removeValue(forKey: id) != nil else { return }
        _ = try? store.writeResultIfAbsent(SudoResult(id: id, status: .denied))
    }
}

