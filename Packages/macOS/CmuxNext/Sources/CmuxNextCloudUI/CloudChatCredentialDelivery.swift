package import CmuxNextCloud
package import CmuxNextDaemon

extension CloudAgentCredentials {
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
        do {
            guard let credential = try await boundCredential(binding, model: status.model, harness: status.harness) else { return }
            guard await replace(credential) == .delivered else { return }
            onDelivered()
            trackModelConnection(credential, chat: chat, machine: machine, surface: surface, sessionID: sessionID, ownerLink: ownerLink,
                                 reconnect: reconnect, endpoint: endpoint) {
                onRefusal(.refused(reason: "chatgpt.reauth_required"), status.harness)
            }
        } catch let failure as Failure {
            guard let connection = await self.connection(forBinding: binding) else { return }
            if !connection.enabled || !connection.signedIn || !connection.servesCloud {
                _ = await replace(nil)
            }
            onRefusal(failure, status.harness)
        } catch {}
    }

    /// Refresh and replace the same credential after launching or reattaching a guest chat.
    package func trackModelConnection(_ credential: CloudAgentCredential, chat: String, machine: String, surface: UInt64, sessionID: String,
                                      ownerLink: AgentSessionAttachClient.OwnerLink?,
                                      reconnect: AgentSessionAttachClient.Reconnect?,
                                      endpoint: @escaping AgentSessionAttachClient.EndpointProvider,
                                      onReauth: @escaping @MainActor () -> Void) {
        started(chat: chat, machine: machine, on: credential, onReauth: onReauth,
                replace: CloudAgentCredentialRefresher.machineReplace(surface: surface, sessionID: sessionID, ownerLink: ownerLink, reconnect: reconnect, endpoint: endpoint),
                push: CloudAgentCredentialRefresher.machinePush(surface: surface, sessionID: sessionID, ownerLink: ownerLink, reconnect: reconnect, endpoint: endpoint))
    }
}
