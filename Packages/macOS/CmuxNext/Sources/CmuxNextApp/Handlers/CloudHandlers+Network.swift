import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextWakeups

extension CloudHandlers {
    static func bindNetworkActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud, rules = CloudHandlerRules()
        bind("cloudTunnelAttach", registry, reason: reason) { invocation in
            let networkID = invocation["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) // none: the joined team
            runTracked("attach Cloud tunnel network", context) { try await AcpmuxCloudTunnel(QuitAgents.environment(context.services), platformOrigin: cloud.configuration.relayAPIBaseURL(), fallback: CloudStrings.tunnelDaemonUnavailable).run(.attach, token: cloud.auth.tokens().access, networkID: networkID) }
        }
        bind("cloudTunnelDetach", registry, reason: reason) { invocation in
            let networkID = invocation["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) // none: the joined team
            runTracked("detach Cloud tunnel network", context) { try await AcpmuxCloudTunnel(QuitAgents.environment(context.services), platformOrigin: cloud.configuration.relayAPIBaseURL(), fallback: CloudStrings.tunnelDaemonUnavailable).run(.detach, token: cloud.auth.tokens().access, networkID: networkID) }
        }
        bind("cloudTunnelRotateKey", registry, reason: reason) { invocation in
            runTracked("rotate Cloud tunnel key", context) { try await AcpmuxCloudTunnel(QuitAgents.environment(context.services), platformOrigin: cloud.configuration.relayAPIBaseURL(), fallback: CloudStrings.tunnelDaemonUnavailable).run(.rekey, token: cloud.auth.tokens().access) }
        }
        bind("cloudNetworkList", registry, reason: reason) { invocation in
            answer("list Cloud networks", invocation, context) {
                let networks = try await cloud.machineAPI.listNetworks()
                let items: [[String: Any]] = networks.map { ["id": $0.id, "scope": $0.scope, "cidr": $0.cidr as Any].compacted }
                return cloudAnswer(CloudStrings.networkTitle, rules.answer(["kind": "networks", "items": items]))
            }
        }
        // The firewall actions called classic cmux.com's /api/vm/firewall, deleted from NEXT; cmux-platform
        // serves no firewall rules yet, so each is unavailable and says so at once.
        let notYet: @MainActor () -> String? = { CloudStrings.firewallNotOnThisCloudYet }
        for id: ActionID in ["cloudFirewallList", "cloudFirewallGet", "cloudFirewallCreate", "cloudFirewallDelete"] {
            bind(id, registry, reason: notYet) { _ in throw ActionFailure(message: CloudStrings.firewallNotOnThisCloudYet) }
        }
        bind("cloudSetNetworkAccess", registry, reason: reason) { invocation in
            try CloudNetworkAccessActions.set(invocation, context)
        }
    }
}
