public import CmuxNextAgentPane
public import CmuxNextDaemon

/// Coordinates the keyed remote start handshake shared by tab hosts.
public enum AgentRemoteStartCoordinator {
    public static func keyedStart<Started: Sendable>(
        _ cwd: String?, _ harness: String?, _ model: String?, approvals: AgentPaneRemoteApprovals?, servesKeyedReason: Bool,
        updateMachine: (@Sendable () async -> Bool)? = nil,
        proceed: @escaping @Sendable () async throws -> Void,
        start unchecked: @escaping @Sendable (String?, String?, String?, AgentSessionAttachClient.PersonKey?) async throws -> Started
    ) async throws -> Started {
        let start = { @Sendable (cwd: String?, harness: String?, model: String?, key: AgentSessionAttachClient.PersonKey?) in
            try await proceed()
            do { return try await unchecked(cwd, harness, model, key) }
            catch let refusal as AgentRemoteStartRefusal where AgentRemoteStartRefusal.olderDaemonCodes.contains(refusal.code) {
                guard let updateMachine, await updateMachine() else { throw refusal }
                try await proceed()
                return try await unchecked(cwd, harness, model, key)
            }
        }
        guard let approvals, let prepare = approvals.prepare else { return try await start(cwd, harness, model, nil) }
        guard servesKeyedReason else {
            try await proceed(); _ = await prepare(.checkStatus)
            return try await start(cwd, harness, model, nil)
        }
        let key = AgentSessionAttachClient.PersonKey(instance: AcpmuxRemotePersonKeys.shared.instance(machine: approvals.machineID))
        do { return try await start(cwd, harness, model, key) }
        catch let refusal as AgentRemoteStartRefusal where refusal.code == AgentSessionAttachError.needsKeyedStart {
            let current = AcpmuxRemotePersonKeys.shared.instance(machine: approvals.machineID)
            if refusal.keyedRestartSafe == true, current == nil || current == key.instance {
                try await proceed(); _ = await prepare(.daemonSaidSafe)
            }
            return try await start(cwd, harness, model, nil)
        }
    }
}
