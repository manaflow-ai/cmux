package import CmuxNextCloud
package import CmuxNextDaemon

extension CloudAgentCredentials {
    /// Reconcile withdrawn connections over owner links without attaching a pane.
    package static func withdrawModelConnections(_ bindings: [String], on guests: [(AgentSessionAttachClient.OwnerLink,
                                                                                     AgentSessionAttachClient.EndpointProvider)]) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for (ownerLink, endpoint) in guests {
                group.addTask { await withdrawModelConnections(bindings, ownerLink: ownerLink, endpoint: endpoint) }
            }
            var delivered = true
            for await result in group { delivered = delivered && result }
            return delivered
        }
    }

    private static func withdrawModelConnections(_ bindings: [String], ownerLink: @escaping AgentSessionAttachClient.OwnerLink,
                                                  endpoint: @escaping AgentSessionAttachClient.EndpointProvider) async -> Bool {
        let client = AgentSessionAttachClient(surface: 0, endpoint: endpoint)
        let delivered: Bool
        do {
            try await client.withdrawCredentials(bindings: bindings, ownerLink: ownerLink)
            delivered = true
        } catch {
            delivered = false
        }
        await client.close()
        return delivered
    }

    /// Reattach to the guest and redeliver its connection's current credential.
    package func restoreModelConnection(chat: String, machine: String, surface: UInt64, sessionID: String,
                                        ownerLink: @escaping AgentSessionAttachClient.OwnerLink,
                                        reconnect: AgentSessionAttachClient.Reconnect?,
                                        endpoint: @escaping AgentSessionAttachClient.EndpointProvider,
                                        onDelivered: @escaping @MainActor () -> Void,
                                        onRefusal: @escaping @MainActor (Failure, String?) -> Void) async {
        let client = AgentSessionAttachClient(surface: surface, reconnect: reconnect, endpoint: endpoint)
        let status = try? await client.credentialStatus(sessionID: sessionID, ownerLink: ownerLink)
        await client.close()
        if let status, status.claudeTokenRecovery == "machineLogin" {
            stopDeliveringCredential(chat: chat, machine: machine, harness: status.harness)
            onDelivered()
            return
        }
        guard let status, let binding = status.connection, binding.contains(":") else { return }
        let replace = CloudAgentCredentialRefresher.machineReplace(surface: surface, sessionID: sessionID, ownerLink: ownerLink,
                                                                   reconnect: reconnect, endpoint: endpoint)
        await restoreBinding(binding, chat: chat, machine: machine, sessionID: sessionID, harness: status.harness, model: status.model,
                             replace: replace, onDelivered: onDelivered) { failure in
            onRefusal(failure, status.harness)
        }
    }

    /// Refresh and replace the same credential after launching or reattaching a guest chat.
    package func trackModelConnection(_ credential: CloudAgentCredential, chat: String, machine: String, surface: UInt64, sessionID: String,
                                      ownerLink: AgentSessionAttachClient.OwnerLink?,
                                      reconnect: AgentSessionAttachClient.Reconnect?,
                                      endpoint: @escaping AgentSessionAttachClient.EndpointProvider,
                                      onReauth: @escaping @MainActor () -> Void) {
        started(chat: chat, machine: machine, sessionID: sessionID, on: credential, onReauth: onReauth,
                replace: CloudAgentCredentialRefresher.machineReplace(surface: surface, sessionID: sessionID, ownerLink: ownerLink, reconnect: reconnect, endpoint: endpoint),
                push: CloudAgentCredentialRefresher.machinePush(surface: surface, sessionID: sessionID, ownerLink: ownerLink, reconnect: reconnect, endpoint: endpoint))
    }
}
