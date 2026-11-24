package import CmuxNextCloud
package import CmuxNextDaemon

extension CloudAgentCredentials {
    /// Reattach to the guest and redeliver its connection's current credential.
    package func restoreModelConnection(chat: String, machine: String, surface: UInt64,
                                        ownerLink: @escaping AgentSessionAttachClient.OwnerLink,
                                        reconnect: AgentSessionAttachClient.Reconnect?,
                                        endpoint: @escaping AgentSessionAttachClient.EndpointProvider,
                                        onDelivered: @MainActor () -> Void,
                                        onRefusal: @escaping @MainActor (Failure, String?) -> Void) async {
        let client = AgentSessionAttachClient(surface: surface, reconnect: reconnect, endpoint: endpoint)
        let status = try? await client.credentialStatus(ownerLink: ownerLink)
        await client.close()
        guard let status, let connection = status.connection else {
            await restoreTrackedConnection(chat: chat, machine: machine)
            return
        }
        let replace = CloudAgentCredentialRefresher.machineReplace(surface: surface, ownerLink: ownerLink,
                                                                   reconnect: reconnect, endpoint: endpoint)
        do {
            let credential = try await self.credential(forConnection: connection, model: status.model, harness: status.harness)
            guard await replace(credential) == .delivered else { return }
            onDelivered()
            trackModelConnection(credential, chat: chat, machine: machine, surface: surface, ownerLink: ownerLink,
                                 reconnect: reconnect, endpoint: endpoint) {
                onRefusal(.refused(reason: "chatgpt.reauth_required"), status.harness)
            }
        } catch let failure as Failure {
            if let ids = await readCredentialConnections?(), !ids.contains(connection) {
                _ = await replace(nil)
            }
            onRefusal(failure, status.harness)
        } catch {}
    }

    /// Refresh and replace the same credential after launching or reattaching a guest chat.
    package func trackModelConnection(_ credential: CloudAgentCredential, chat: String, machine: String, surface: UInt64,
                                      ownerLink: AgentSessionAttachClient.OwnerLink?,
                                      reconnect: AgentSessionAttachClient.Reconnect?,
                                      endpoint: @escaping AgentSessionAttachClient.EndpointProvider,
                                      onReauth: @escaping @MainActor () -> Void) {
        started(chat: chat, machine: machine, on: credential, onReauth: onReauth,
                replace: CloudAgentCredentialRefresher.machineReplace(surface: surface, ownerLink: ownerLink, reconnect: reconnect, endpoint: endpoint),
                push: CloudAgentCredentialRefresher.machinePush(surface: surface, ownerLink: ownerLink, reconnect: reconnect, endpoint: endpoint))
    }
}
