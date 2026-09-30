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
            return Int(exactly: number)
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

    /// `vm.agent_fan_out` creates the workspace first, then records the
    /// operation before starting a child. A duplicate operation id returns the
    /// recorded operation without touching the provider.
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
                    return existing.foundationObject
                }
                return try await Self.createFanOutOperation(
                    operationID: requestedOperationID, machineID: machineID, scope: scope,
                    agent: agent, argv: argv, count: count, params: params, digest: digest
                )
            }
        }
        return v2VmCall(id: id, timeoutSeconds: 240) {
            guard let scope = await Self.currentFanOutScope() else { throw FanOutSocketError.unauthenticated }
            try await Self.createFanOutOperation(
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
        let provider = try await cloudTuiProvider(machineID: machineID, catalog: catalog)
        let explicitWorkspace = fanOutString(params["remote_workspace_id"])
        let open = (params["open"] as? Bool) ?? false
        let focus = (params["focus"] as? Bool) ?? false
        let namePrefix = fanOutString(params["name_prefix"]) ?? "\(agent) fan-out"
        let generatedID = operationID ?? "f_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())"
        let destination: SurfaceDestination?
        if open, let workspaceID = TerminalController.shared.surfaceTargetWorkspaceID(params, strictExplicit: true) {
            destination = Self.surfaceDestination(surfaceResolvedParams(params), workspaceID: workspaceID)
        } else if open {
            throw FanOutSocketError.destinationRequired
        } else {
            destination = nil
        }
        let now = Date()
        var operation = AgentFanOutOperation(
            id: generatedID, machineID: machineID, scope: scope,
            // Reserve the operation before creating a workspace. A concurrent
            // request carrying this id then observes this record and cannot
            // create a second workspace or child set.
            remoteWorkspaceID: "", agent: agent, argvDigest: digest,
            requestedCount: count, createdAt: now, updatedAt: now, state: .creating,
            children: (0..<count).map { AgentFanOutChild(index: $0, terminalID: nil, state: .starting, exitCode: nil, errorCode: nil, startedAt: nil, endedAt: nil) }
        )
        guard try await AgentFanOutOperationStore.shared.insertIfAbsent(operation) else {
            if let existing = try await AgentFanOutOperationStore.shared.operation(id: generatedID) {
                guard existing.scope == scope, existing.machineID == machineID,
                      existing.agent == agent, existing.argvDigest == digest,
                      existing.requestedCount == count else {
                    throw FanOutSocketError.conflictingOperation
                }
                return existing.foundationObject
            }
            throw FanOutSocketError.conflictingOperation
        }
        let remoteWorkspace: SurfaceRemoteWorkspace
        do {
            if let explicitWorkspace {
                remoteWorkspace = SurfaceRemoteWorkspace(id: explicitWorkspace, name: explicitWorkspace, index: 0, focused: false)
            } else {
                remoteWorkspace = try await provider.createRemoteWorkspace(name: "\(namePrefix) · fan-out \(generatedID.suffix(8))")
            }
        } catch {
            operation.state = .failed
            operation.updatedAt = Date()
            for index in operation.children.indices {
                operation.children[index].state = .failed
                operation.children[index].errorCode = "workspace_create_failed"
                operation.children[index].endedAt = operation.updatedAt
            }
            try await AgentFanOutOperationStore.shared.update(operation)
            throw error
        }
        operation.remoteWorkspaceID = remoteWorkspace.id
        operation.updatedAt = Date()
        try await AgentFanOutOperationStore.shared.update(operation)
        for index in operation.children.indices {
            do {
                let childName = "\(namePrefix) [\(index + 1)/\(count)]"
                let response = try await Self.surfaceNewTerminal(
                    machine: .cloud(machineID), command: argv, cwd: Self.fanOutString(params["cwd"]),
                    name: childName, remoteWorkspaceID: remoteWorkspace.id,
                    destination: destination, focus: focus
                )
                guard let terminalID = Self.fanOutString(response["terminal_id"]) else {
                    operation.children[index].state = .failed
                    operation.children[index].errorCode = "terminal_id_missing"
                    operation.children[index].endedAt = Date()
                    operation.recomputeState()
                    try await AgentFanOutOperationStore.shared.update(operation)
                    continue
                }
                operation.children[index].terminalID = terminalID
                operation.children[index].state = .running
                operation.children[index].startedAt = Date()
            } catch {
                operation.children[index].state = .failed
                operation.children[index].errorCode = String(describing: error).prefix(120).description
                operation.children[index].endedAt = Date()
            }
            operation.recomputeState()
            try await AgentFanOutOperationStore.shared.update(operation)
        }
        operation.recomputeState()
        try await AgentFanOutOperationStore.shared.update(operation)
        return operation.foundationObject
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
            let result = try await provider.waitForExit(terminalID: terminalID, timeoutMs: 1)
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
}

private enum FanOutSocketError: LocalizedError {
    case conflictingOperation, machineUnavailable, destinationRequired, operationNotFound, unauthenticated
    var errorDescription: String {
        switch self {
        case .conflictingOperation: return "operation_id already names a different fan-out request"
        case .machineUnavailable: return "Cloud machine is unavailable"
        case .destinationRequired: return "open fan-out requires an explicit workspace_id"
        case .operationNotFound: return "fan-out operation was not found"
        case .unauthenticated: return "Cloud authentication is required for fan-out operations"
        }
    }
}
