import CmuxCloud
import CmuxControlSocket
import CmuxSurfaceCatalogModel
import Foundation

/// Socket operations for durable groups of detached agent terminals.  The
/// provider remains the only owner of terminal creation; this layer only
/// records the operation and coordinates the returned identities.
extension TerminalController {
    private nonisolated static func currentFanOutScope() async -> String? {
        await MainActor.run {
            AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope.map {
                // Account and team identify the authorization boundary. The
                // auth generation is intentionally excluded: refreshing a
                // token or restarting cmux must not hide this user's records.
                "\($0.session.accountID):\($0.teamID)"
            }
        }
    }

    private nonisolated static func fanOutString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private nonisolated static func fanOutStringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return value as? [String] }
        guard values.allSatisfy({ $0 is String }) else { return nil }
        return values.compactMap { $0 as? String }
    }

    private nonisolated static func fanOutInt(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            guard ["c", "i", "s", "l", "q", "C", "I", "S", "L", "Q"].contains(type) else { return nil }
            return number.intValue
        }
        return (value as? String).flatMap(Int.init)
    }

    private nonisolated static func fanOutRequestDigest(argv: [String], params: [String: Any]) -> String {
        let keys = ["cwd", "remote_workspace_id", "open", "focus", "name_prefix", "workspace_id", "pane_id", "surface_id", "direction", "tab_index", "placement"]
        let identity = keys.reduce(into: [String: String]()) { result, key in
            if let value = params[key] { result[key] = String(describing: value) }
        }
        return AgentFanOutOperation.digest(argv: argv, identity: identity)
    }

    private nonisolated static func fanOutChildCorrelationKey(operationID: String, index: Int) -> String {
        "cmux-agent-fan-out-\(AgentFanOutOperation.digest(argv: [operationID, String(index)]))"
    }

    /// `vm.agent_fan_out` records the operation before creating child
    /// workspaces. A duplicate operation id returns the recorded operation
    /// without touching the provider.
    nonisolated func socketWorkerVMAgentFanOutResponse(id: Any?, params: [String: Any]) -> String {
        guard let machineID = Self.fanOutString(params["machine"] ?? params["id"]),
              let agent = Self.fanOutString(params["agent"])?.lowercased(),
              let count = Self.fanOutInt(params["count"]) else {
            return v2Error(id: id, code: "invalid_params", message: "vm.agent_fan_out requires machine, agent, non-empty argv, and count 1…\(AgentFanOutOperation.maximumCount).")
        }
        guard let argv = Self.fanOutStringArray(params["argv"]) else {
            return v2Error(id: id, code: "invalid_params", message: "vm.agent_fan_out: argv must be an array of strings")
        }
        if let validationError = AgentFanOutOperation.validate(machineID: machineID, agent: agent, argv: argv, count: count) {
            return v2Error(id: id, code: "invalid_params", message: "vm.agent_fan_out: \(validationError)")
        }
        let digest = Self.fanOutRequestDigest(argv: argv, params: params)
        let requestedOperationID = Self.fanOutString(params["operation_id"])
        if let requestedOperationID {
            return v2VmCall(id: id, timeoutSeconds: 240) {
                guard let scope = await Self.currentFanOutScope() else { throw FanOutSocketError.unauthenticated }
                if let existing = try await AgentFanOutOperationStore.shared.operation(id: requestedOperationID) {
                    guard existing.scope == scope, existing.machineID == machineID,
                          existing.agent == agent, existing.argvDigest == digest,
                          existing.requestedCount == count else {
                        throw FanOutSocketError.conflictingOperation
                    }
                    guard try await AgentFanOutOperationStore.shared.beginCreation(id: existing.id) else {
                        return existing.foundationObject
                    }
                    do {
                        let reconciled = try await Self.reconcileStartingFanOutChildren(
                            existing, machineID: machineID, agent: agent, argv: argv, params: params
                        )
                        await AgentFanOutOperationStore.shared.endCreation(id: existing.id)
                        return reconciled.foundationObject
                    } catch {
                        await AgentFanOutOperationStore.shared.endCreation(id: existing.id)
                        throw error
                    }
                }
                return try await Self.createFanOutOperation(
                    operationID: requestedOperationID, machineID: machineID, scope: scope,
                    agent: agent, argv: argv, count: count, params: params, digest: digest
                )
            }
        }
        return v2VmCall(id: id, timeoutSeconds: 240) {
            guard let scope = await Self.currentFanOutScope() else { throw FanOutSocketError.unauthenticated }
            return try await Self.createFanOutOperation(
                operationID: nil, machineID: machineID, scope: scope,
                agent: agent, argv: argv, count: count, params: params, digest: digest
            )
        }
    }

    private nonisolated static func createFanOutOperation(
        operationID: String?, machineID: String, scope: String, agent: String,
        argv: [String], count: Int, params: [String: Any], digest: String
    ) async throws -> [String: Any] {
        let catalog = await SurfaceCatalog.shared
        let explicitWorkspace = fanOutString(params["remote_workspace_id"])
        let open = (params["open"] as? Bool) ?? false
        let focus = (params["focus"] as? Bool) ?? false
        let namePrefix = fanOutString(params["name_prefix"]) ?? "\(agent) fan-out"
        let generatedID = operationID ?? "f_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())"
        let targetID = open ? await MainActor.run {
            TerminalController.shared.surfaceTargetWorkspaceID(params, strictExplicit: true)
        } : nil
        let destination = await MainActor.run {
            targetID.map {
                Self.surfaceDestination(TerminalController.shared.surfaceResolvedParams(params), workspaceID: $0)
            }
        }
        if open, explicitWorkspace != nil, destination == nil {
            throw FanOutSocketError.destinationRequired
        }
        // Capture the caller's window before connecting to the machine. An
        // invalid explicit target must fail before creating remote resources.
        let host: CloudWorkspaceCreationHost? = try await MainActor.run {
            guard open, explicitWorkspace == nil else { return nil }
            let manager: TabManager?
            if let targetID {
                manager = Workspace.liveWorkspace(id: targetID)?.owningTabManager
            } else if params["workspace_id"] != nil {
                throw FanOutSocketError.destinationRequired
            } else {
                manager = AppDelegate.shared?.preferredMainWindowContextForWorkspaceCreation(
                    debugSource: "agent.fan-out"
                )?.tabManager
            }
            guard let manager else { throw FanOutSocketError.destinationRequired }
            return CloudWorkspaceCreationHost(manager: manager)
        }
        let provider = try await cloudTuiProvider(machineID: machineID, catalog: catalog)
        guard await Self.currentFanOutScope() == scope else { throw FanOutSocketError.unauthenticated }
        let now = Date()
        var operation = AgentFanOutOperation(
            id: generatedID, machineID: machineID, scope: scope,
            remoteWorkspaceID: explicitWorkspace ?? "", sharedWorkspace: explicitWorkspace != nil,
            agent: agent, argvDigest: digest,
            requestedCount: count, createdAt: now, updatedAt: now, state: .creating,
            children: (0..<count).map {
                AgentFanOutChild(
                    index: $0,
                    creationCorrelationKey: Self.fanOutChildCorrelationKey(operationID: generatedID, index: $0),
                    terminalID: nil, state: .starting, exitCode: nil, errorCode: nil, startedAt: nil, endedAt: nil
                )
            }
        )
        // Reserve the id before the first remote mutation. Concurrent retries
        // observe this record and cannot create a second child set.
        guard try await AgentFanOutOperationStore.shared.insertIfAbsent(operation) else {
            if let existing = try await AgentFanOutOperationStore.shared.operation(id: generatedID),
               existing.scope == scope, existing.machineID == machineID,
               existing.agent == agent, existing.argvDigest == digest,
               existing.requestedCount == count {
                return existing.foundationObject
            }
            throw FanOutSocketError.conflictingOperation
        }
        guard try await AgentFanOutOperationStore.shared.beginCreation(id: operation.id) else {
            return operation.foundationObject
        }
        defer {
            Task { await AgentFanOutOperationStore.shared.endCreation(id: operation.id) }
        }
        for index in operation.children.indices {
            var ownedWorkspace: SurfaceRemoteWorkspace?
            var stage = "workspace_create_failed"
            do {
                try Task.checkCancellation()
                guard await Self.currentFanOutScope() == scope else { throw FanOutSocketError.unauthenticated }
                let childName = "\(namePrefix) [\(index + 1)/\(count)]"
                let workspace: SurfaceRemoteWorkspace
                if let explicitWorkspace {
                    workspace = SurfaceRemoteWorkspace(id: explicitWorkspace, name: explicitWorkspace, index: 0, focused: false)
                } else {
                    let receipt = try await provider.createEmptyRemoteWorkspaceReceipt(name: childName)
                    workspace = receipt.workspace
                    ownedWorkspace = workspace
                    // Compatibility with a daemon that still supplies a starter:
                    // remove only the exact terminal named by its receipt.
                    if let starter = receipt.terminal {
                        guard await Self.currentFanOutScope() == scope else { throw FanOutSocketError.unauthenticated }
                        try await provider.closeTerminal(starter.id, remoteWorkspaceID: workspace.id)
                    }
                }
                operation.children[index].remoteWorkspaceID = workspace.id
                if operation.remoteWorkspaceID.isEmpty { operation.remoteWorkspaceID = workspace.id }
                try await AgentFanOutOperationStore.shared.update(operation)
                stage = "terminal_create_failed"
                guard await Self.currentFanOutScope() == scope else { throw FanOutSocketError.unauthenticated }
                let correlationKey = operation.children[index].creationCorrelationKey
                    ?? Self.fanOutChildCorrelationKey(operationID: generatedID, index: index)
                operation.children[index].creationCorrelationKey = correlationKey
                let request = await MainActor.run {
                    CloudTerminalCreationRequest(
                        correlationKey: correlationKey, remoteWorkspaceID: workspace.id,
                        commandOverride: argv, restoring: true
                    )
                }
                let terminal = try await provider.createTerminal(
                    command: argv, cwd: Self.fanOutString(params["cwd"]), name: childName,
                    remoteWorkspaceID: workspace.id, onExit: "keep", request: request
                )
                operation.children[index].terminalID = terminal.id.key
                operation.children[index].state = .running
                operation.children[index].startedAt = Date()
                operation.recomputeState()
                // Persist the remote receipt before attempting local attachment.
                // A failed open must neither kill the agent nor erase its identity.
                try await AgentFanOutOperationStore.shared.update(operation)
                if open {
                    do {
                        guard await Self.currentFanOutScope() == scope else { throw FanOutSocketError.unauthenticated }
                        if let destination {
                            if explicitWorkspace != nil {
                                let view = try CloudTerminalSourcePlacement(machine: .cloud(machineID), remoteWorkspaceID: workspace.id).remoteView(of: terminal)
                                let opened = try await catalog.project(terminal.id, into: destination, focus: focus && index == 0, reuseExisting: false, remoteView: view)
                                operation.children[index].localWorkspaceID = opened.projection.workspaceID.uuidString
                            } else {
                                let opened = try await Self.openFanOutChild(workspace, terminal: terminal, provider: provider, catalog: catalog, host: host, scope: scope, focus: focus && index == 0)
                                operation.children[index].localWorkspaceID = opened
                            }
                        } else {
                            let opened = try await Self.openFanOutChild(workspace, terminal: terminal, provider: provider, catalog: catalog, host: host, scope: scope, focus: focus && index == 0)
                            operation.children[index].localWorkspaceID = opened
                        }
                    } catch {
                        operation.children[index].projectionErrorCode = "local_projection_failed"
                    }
                }
            } catch {
                // Never persist arbitrary provider diagnostics: they can contain
                // command output or secrets. A committed terminal remains live.
                if operation.children[index].terminalID == nil {
                    if let ownedWorkspace, await Self.currentFanOutScope() == scope {
                        try? await provider.closeRemoteWorkspace(id: ownedWorkspace.id)
                    }
                    operation.children[index].state = .failed
                    operation.children[index].errorCode = error is CancellationError ? "fan_out_cancelled" : stage
                    operation.children[index].endedAt = Date()
                }
                operation.recomputeState()
                try await AgentFanOutOperationStore.shared.update(operation)
                if operation.children[index].terminalID != nil { throw error }
            }
            operation.recomputeState()
            try await AgentFanOutOperationStore.shared.update(operation)
        }
        guard await Self.currentFanOutScope() == scope else { throw FanOutSocketError.unauthenticated }
        return operation.foundationObject
    }

    @MainActor
    private static func openFanOutChild(
        _ workspace: SurfaceRemoteWorkspace, terminal: SurfaceResource,
        provider: CmuxTuiSurfaceProvider, catalog: SurfaceCatalog,
        host: CloudWorkspaceCreationHost?, scope: String, focus: Bool
    ) async throws -> String? {
        guard let host, host.isAvailable else { throw FanOutSocketError.destinationRequired }
        let opened = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
            machine: provider.machine, provider: provider, catalog: catalog,
            name: workspace.name, focus: focus,
            existingWorkspace: workspace, existingTerminal: terminal, host: host,
            validateOperation: {
                try Task.checkCancellation()
                guard let auth = AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope,
                      "\(auth.session.accountID):\(auth.teamID)" == scope else {
                    throw FanOutSocketError.unauthenticated
                }
            }
        )
        return opened.opened?.workspaceID.uuidString
    }

    nonisolated func socketWorkerVMAgentFanOutStatusResponse(id: Any?, params: [String: Any], wait: Bool) -> String {
        guard let operationID = Self.fanOutString(params["operation_id"]), !operationID.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.agent_fan_out_\(wait ? "wait" : "status") requires operation_id.")
        }
        let timeoutMs = max(0, min(30_000, Self.fanOutInt(params["timeout_ms"]) ?? (wait ? 30_000 : 0)))
        return v2VmCall(id: id, timeoutSeconds: TimeInterval(timeoutMs) / 1000 + 30) {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMs))
            while true {
                guard var operation = try await AgentFanOutOperationStore.shared.operation(id: operationID) else {
                    throw FanOutSocketError.operationNotFound
                }
                guard let scope = await Self.currentFanOutScope() else { throw FanOutSocketError.unauthenticated }
                guard operation.scope == scope else {
                    throw FanOutSocketError.operationNotFound
                }
                operation = try await Self.refreshFanOutChildren(operation)
                guard let merged = try await AgentFanOutOperationStore.shared.mergeTerminalExits(operation) else {
                    throw FanOutSocketError.operationNotFound
                }
                operation = merged
                if !wait || operation.settledCount == operation.requestedCount || ContinuousClock.now >= deadline {
                    return operation.foundationObject
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private nonisolated static func refreshFanOutChildren(_ operation: AgentFanOutOperation) async throws -> AgentFanOutOperation {
        var operation = operation
        let provider = try await cloudTuiProvider(machineID: operation.machineID, catalog: await SurfaceCatalog.shared)
        for index in operation.children.indices where operation.children[index].state == .running {
            guard let terminalID = operation.children[index].terminalID else {
                operation.children[index].state = .failed
                operation.children[index].errorCode = "missing_terminal_id"
                operation.children[index].endedAt = Date()
                continue
            }
            let result: [String: Any]
            do {
                result = try await provider.waitForExit(terminalID: terminalID, timeoutMs: 1)
            } catch {
                // A confirmed missing terminal is permanently unobservable;
                // transport, link, and machine availability failures remain
                // running so a later status request can retry them.
                let isMissing: Bool
                if let providerError = error as? CmuxTuiSurfaceProvider.ProviderError {
                    if case .remoteTabNotFound = providerError {
                        isMissing = true
                    } else {
                        isMissing = false
                    }
                } else {
                    isMissing = CloudDiagnosticFailure.classify(error) == .notFound
                }
                if isMissing {
                    operation.children[index].state = .failed
                    operation.children[index].errorCode = "terminal_unavailable"
                    operation.children[index].endedAt = Date()
                }
                continue
            }
            guard (result["state"] as? String) == "exited" else { continue }
            var exitCode: Int?
            if let outcome = result["outcome"] as? [String: Any] {
                exitCode = outcome["code"] as? Int
            }
            operation.children[index].exitCode = exitCode
            if let exitCode, exitCode != 0 {
                operation.children[index].state = .failed
                operation.children[index].errorCode = "agent_exit_nonzero"
            } else {
                operation.children[index].state = .exited
            }
            operation.children[index].endedAt = Date()
        }
        operation.recomputeState()
        return operation
    }

    /// A terminal mutation can commit remotely just before the local ledger
    /// write fails. On a retry, resolve each durable child identity first so a
    /// committed receipt is adopted instead of creating a second terminal.
    private nonisolated static func reconcileStartingFanOutChildren(
        _ operation: AgentFanOutOperation, machineID: String, agent: String,
        argv: [String], params: [String: Any]
    ) async throws -> AgentFanOutOperation {
        var operation = operation
        if let explicitWorkspace = fanOutString(params["remote_workspace_id"]),
           operation.sharedWorkspace == true || operation.remoteWorkspaceID == explicitWorkspace {
            operation.adoptExplicitWorkspaceForRecovery(explicitWorkspace)
            // Persist the repaired shared-workspace receipt before any daemon
            // mutation so a second retry has the same idempotent identity.
            try? await AgentFanOutOperationStore.shared.update(operation)
        }
        operation.prepareForRecovery()
        try? await AgentFanOutOperationStore.shared.update(operation)
        guard operation.children.contains(where: {
            $0.state == .starting && $0.creationCorrelationKey != nil && $0.remoteWorkspaceID != nil
        }) else { return operation }
        let provider = try await cloudTuiProvider(machineID: machineID, catalog: await SurfaceCatalog.shared)
        let namePrefix = fanOutString(params["name_prefix"]) ?? "\(agent) fan-out"
        for index in operation.children.indices where operation.children[index].state == .starting {
            guard let workspaceID = operation.children[index].remoteWorkspaceID,
                  let correlationKey = operation.children[index].creationCorrelationKey else { continue }
            let childName = "\(namePrefix) [\(index + 1)/\(operation.requestedCount)]"
            do {
                let request = await MainActor.run {
                    CloudTerminalCreationRequest(
                        correlationKey: correlationKey, remoteWorkspaceID: workspaceID,
                        commandOverride: argv, restoring: true
                    )
                }
                let terminal = try await provider.createTerminal(
                    command: argv, cwd: fanOutString(params["cwd"]), name: childName,
                    remoteWorkspaceID: workspaceID, onExit: "keep", request: request
                )
                operation.children[index].terminalID = terminal.id.key
                operation.children[index].state = .running
                operation.children[index].startedAt = operation.children[index].startedAt ?? Date()
                operation.recomputeState()
                // A transient write failure leaves the child starting; the
                // same correlation key will reconcile it on the next retry.
                try? await AgentFanOutOperationStore.shared.update(operation)
            } catch {
                // Pending or unavailable daemon work must remain retryable.
                continue
            }
        }
        return (try? await AgentFanOutOperationStore.shared.operation(id: operation.id)) ?? operation
    }
}

private enum FanOutSocketError: LocalizedError {
    case conflictingOperation, machineUnavailable, destinationRequired, operationNotFound, unauthenticated
    var errorDescription: String? {
        switch self {
        case .conflictingOperation: return "operation_id already names a different fan-out request"
        case .machineUnavailable: return "Cloud machine is unavailable"
        case .destinationRequired: return "open fan-out requires an explicit workspace_id"
        case .operationNotFound: return "fan-out operation was not found"
        case .unauthenticated: return "Cloud authentication is required for fan-out operations"
        }
    }
}
