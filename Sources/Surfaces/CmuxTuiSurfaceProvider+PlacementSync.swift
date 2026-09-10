import Foundation

/// Revision-fenced placement edits, retried once with fresh destination coordinates.
@MainActor
extension CmuxTuiSurfaceProvider: SurfacePlacementSyncing {
    enum TerminalPlacementIntent {
        case attachment
        case layoutEdit

        /// A reconnect/viewer preserves any existing view. Only an explicit
        /// layout edit can request that the unique view change workspaces.
        func retainedPlacement(_ existing: SurfaceRemotePlacement, requestedWorkspaceID: String) -> SurfaceRemotePlacement? {
            self == .attachment || existing.workspaceID == requestedWorkspaceID ? existing : nil
        }
    }

    func moveRemoteTab(id: String, intoRemoteWorkspace remoteWorkspaceID: String) async throws -> SurfaceRemotePlacement {
        try await runPlacementMutation(intoRemoteWorkspace: remoteWorkspaceID, tabID: id) { socketPath, target, revision, key in
            CloudTuiCommandLine.moveTabArguments(
                socketPath: socketPath, tabID: id, target: target, expectedRevision: revision, idempotencyKey: key
            )
        }
    }

    func projectTerminal(_ id: SurfaceResourceID, intoRemoteWorkspace remoteWorkspaceID: String) async throws -> SurfaceRemotePlacement {
        try await placeTerminal(id, intoRemoteWorkspace: remoteWorkspaceID, intent: .layoutEdit)
    }

    func ensureTerminalAttachment(_ id: SurfaceResourceID, preferringRemoteWorkspace remoteWorkspaceID: String) async throws -> SurfaceRemotePlacement {
        try await placeTerminal(id, intoRemoteWorkspace: remoteWorkspaceID, intent: .attachment)
    }

    private func placeTerminal(_ id: SurfaceResourceID, intoRemoteWorkspace remoteWorkspaceID: String, intent: TerminalPlacementIntent) async throws -> SurfaceRemotePlacement {
        try await runPlacementMutation(intoRemoteWorkspace: remoteWorkspaceID, terminalID: id.key, intent: intent) { socketPath, target, revision, key in
            CloudTuiCommandLine.projectTerminalArguments(
                socketPath: socketPath, terminalID: id.key, target: target, expectedRevision: revision, idempotencyKey: key
            )
        }
    }

    func closeRemoteTab(id: String, inRemoteWorkspace remoteWorkspaceID: String) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let key = "cmux-cloud-close-\(UUID().uuidString.lowercased())"
        var retried = false
        defer { scheduleRefresh() }
        while true {
            let snapshot = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: connected.socketPath))
            guard let placement = await CmuxTuiSnapshotParser.tabPlacement(from: snapshot, tabID: id) else {
                throw ProviderError.noWorkspaceOnMachine(machineID)
            }
            guard placement.workspaceID == remoteWorkspaceID else { return }
            var arguments = CloudTuiCommandLine.closeTabArguments(socketPath: connected.socketPath, tabID: id)
            arguments += ["--idempotency-key", key]
            arguments += ["--expected-revision", placement.revision]
            do {
                _ = try await link.run(arguments: arguments)
                return
            } catch {
                if Self.isSelectorNotFound(error) { return }
                guard !retried, Self.isRevisionConflict(error) else { throw error }
                retried = true
            }
        }
    }

    private func runPlacementMutation(
        intoRemoteWorkspace remoteWorkspaceID: String,
        tabID: String? = nil,
        terminalID: String? = nil,
        intent: TerminalPlacementIntent = .layoutEdit,
        arguments: (_ socketPath: String, _ target: CloudTuiTerminalProjectionTarget, _ revision: String?, _ idempotencyKey: String) -> [String]
    ) async throws -> SurfaceRemotePlacement {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let key = "cmux-cloud-placement-\(UUID().uuidString.lowercased())"
        var retried = false
        defer { scheduleRefresh() }
        while true {
            try Task.checkCancellation()
            let snapshot = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: connected.socketPath))
            guard let destination = await CmuxTuiSnapshotParser.terminalProjectionTarget(from: snapshot, preferringWorkspace: remoteWorkspaceID),
                  destination.revision != nil else {
                throw ProviderError.noWorkspaceOnMachine(machineID)
            }
            var existingTabID = tabID
            var command = arguments(connected.socketPath, destination.target, destination.revision, key)
            if let terminalID {
                guard let current = await CmuxTuiSnapshotParser.terminalPlacement(from: snapshot, terminalID: terminalID) else {
                    throw ProviderError.terminalNotCreated(terminalID)
                }
                if let placement = current.placement {
                    if let retained = intent.retainedPlacement(placement, requestedWorkspaceID: remoteWorkspaceID) { return retained }
                    existingTabID = placement.tabID
                    command = CloudTuiCommandLine.moveTabArguments(
                        socketPath: connected.socketPath, tabID: placement.tabID, target: destination.target,
                        expectedRevision: destination.revision, idempotencyKey: key
                    )
                }
            }
            do {
                let response = try await link.run(arguments: command)
                guard let placement = await CmuxTuiSnapshotParser.placedTab(
                    from: response, at: destination.target, tabID: existingTabID, terminalID: terminalID
                ) else { throw ProviderError.terminalNotCreated(terminalID ?? tabID ?? remoteWorkspaceID) }
                return placement
            } catch {
                guard !retried, destination.revision != nil, Self.isRevisionConflict(error) else { throw error }
                retried = true
            }
        }
    }
}
