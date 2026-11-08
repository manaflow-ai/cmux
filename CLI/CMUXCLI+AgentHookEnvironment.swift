import Foundation
import CMUXAgentLaunch

/// Captures local hook identity and the bounded environment carried by relayed hooks.
extension CMUXCLI {
    /// Captures the identity shared by queued lifecycle events and direct
    /// decision barriers. Relay callers carry their portable TTY separately so
    /// the app can resolve routing in the admission RPC itself.
    func agentHookOrderingEnvironment(
        agent: String,
        client: SocketClient,
        socketPassword: String? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        resolvesProcessRoute: Bool = true,
        runsInHookProcess: Bool = true
    ) -> [String: String] {
        var environment = AgentLaunchEnvironmentPolicy().selectedEnvironment(
            from: processEnvironment,
            kind: agent
        )
        for key in Self.queuedAgentHookDataEnvironmentKeys(agent: agent) {
            if let value = processEnvironment[key] {
                environment[key] = value
            }
        }
        // A relayed hook can be replayed through a local socket. Its surface
        // scope is already admitted; local PID inference or resolution would
        // move the ordering barrier into an unrelated terminal's lane.
        if !client.isRelayBacked, processEnvironment["CMUX_AGENT_HOOK_RELAY_ORIGIN"] == "1" {
            return environment
        }
        let pidEnvironmentKey = Self.agentHookPIDEnvironmentVariable(agentName: agent)
        // A spool record names the process that ran its hook; a CLI hook is
        // that process's descendant.
        let recordedInvokerPID = environment.removeValue(
            forKey: AgentHookDeliveryPolicy.invokerPIDEnvironmentKey
        ).flatMap(Int.init)
        if !client.isRelayBacked, runsInHookProcess || recordedInvokerPID != nil {
            // The exported PID can be inherited from an agent in another pane
            // (#20186); the agent that ran this hook names the hook's pane.
            if let agentPID = AgentHookDeliveryPolicy().hookAgentPID(
                environmentPID: environment[pidEnvironmentKey].flatMap(Int.init),
                invocationAgentPID: runsInHookProcess ? inferredAgentPID() : recordedInvokerPID,
                controllingTerminal: controllingTerminalDevice(of:)
            ) {
                environment[pidEnvironmentKey] = String(agentPID)
            }
        } else if environment[pidEnvironmentKey].flatMap(Int.init).map({ $0 > 0 }) != true,
           let inferredPID = inferredAgentPID() {
            environment[pidEnvironmentKey] = String(inferredPID)
        }
        // On Kiro CLI V3 the hook's parent pid is not the kiro-cli process. Resolve
        // only from this live, local hook's own ancestry, never a relayed or
        // recorded pid that may name a reused local process.
        if agent == "kiro", !client.isRelayBacked, resolvesProcessRoute, runsInHookProcess,
           environment[pidEnvironmentKey] != nil,
           let kiroCLI = kiroCLIAncestorPID() {
            environment[pidEnvironmentKey] = String(kiroCLI)
        }
        guard client.isRelayBacked else {
            let routeWasAlreadySnapshotted =
                environment[Self.agentHookRouteSnapshotEnvironmentKey] == "1"
            // An exited agent's PID may already belong to another process.
            if resolvesProcessRoute,
               let processID = environment[pidEnvironmentKey].flatMap(Int.init),
               let binding = admittedAgentHookRoute(
                   processID: processID,
                   client: client,
                   socketPassword: socketPassword
               ) {
                environment["CMUX_WORKSPACE_ID"] = binding.workspaceId
                environment["CMUX_SURFACE_ID"] = binding.surfaceId
                environment[Self.agentHookRouteSnapshotEnvironmentKey] = "1"
            } else if !routeWasAlreadySnapshotted {
                environment.removeValue(forKey: Self.agentHookRouteSnapshotEnvironmentKey)
            }
            return environment
        }

        let relayEnvironmentKeys: Set<String> = [
            "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
            "CMUX_AGENT_MANAGED_SUBAGENT",
            "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
            "CMUX_SURFACE_ID",
            "CMUX_WORKSPACE_ID",
            pidEnvironmentKey,
        ]
        return environment.filter { key, value in
            guard relayEnvironmentKeys.contains(key), !value.contains("\0") else {
                return false
            }
            let maximumBytes = key == "CMUX_SURFACE_ID" || key == "CMUX_WORKSPACE_ID"
                ? 256
                : 32
            return value.utf8.count <= maximumBytes
        }
    }
}
