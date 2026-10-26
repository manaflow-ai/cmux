import AppKit
import CmuxNextActions
import CmuxNextCloud

extension CloudHandlers {
    static func bindNetworkActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        bind("cloudTunnelAttach", registry, reason: reason) { invocation in
            let networkID = try idArgument(invocation, CloudStrings.networkIDRequired)
            runTracked("attach Cloud tunnel network", context) { try await cloud.api.attachTunnelNetwork(deviceFingerprint: cloud.localDeviceID(), networkID: networkID) }
        }
        bind("cloudTunnelDetach", registry, reason: reason) { invocation in
            let networkID = try idArgument(invocation, CloudStrings.networkIDRequired)
            runTracked("detach Cloud tunnel network", context) { try await cloud.api.detachTunnelNetwork(deviceFingerprint: cloud.localDeviceID(), networkID: networkID) }
        }
        bind("cloudTunnelRotateKey", registry, reason: reason) { invocation in
            guard let key = invocation["publicKey"]?.stringValue else { throw ActionFailure(message: CloudStrings.tunnelKeyRequired) }
            runTracked("rotate Cloud tunnel key", context) { _ = try await cloud.api.rotateTunnelKey(deviceFingerprint: cloud.localDeviceID(), publicKey: key) }
        }
        bind("cloudNetworkList", registry, reason: reason) { invocation in
            answer("list Cloud networks", invocation, context) {
                let networks = try await cloud.api.listNetworks()
                let lines = networks.map { network in [network.id, "(\(network.scope))", network.cidr ?? ""].joined(separator: " ") }
                return CloudAnswer(title: CloudStrings.networkTitle, text: lines.joined(separator: "\n"), fields: ["count": .int(networks.count)])
            }
        }
        bind("cloudFirewallList", registry, reason: reason) { invocation in
            answer("list Cloud firewall rules", invocation, context) {
                let rules = try await cloud.api.listFirewallRules()
                return CloudAnswer(title: CloudStrings.firewallTitle, text: rules.map { "\($0.id): \($0.description ?? $0.action)" }.joined(separator: "\n"),
                                   fields: ["count": .int(rules.count)])
            }
        }
        bind("cloudFirewallGet", registry, reason: reason) { invocation in
            let ruleID = try idArgument(invocation, CloudStrings.ruleIDRequired)
            answer("get Cloud firewall rule", invocation, context) {
                let rule = try await cloud.api.getFirewallRule(ruleID)
                return CloudAnswer(title: CloudStrings.firewallTitle, text: "\(rule.id): \(rule.description ?? rule.action)",
                                   fields: ["id": .string(rule.id), "action": .string(rule.action)])
            }
        }
        bind("cloudFirewallDelete", registry, reason: reason) { invocation in
            let ruleID = try idArgument(invocation, CloudStrings.ruleIDRequired)
            runTracked("delete Cloud firewall rule", context) { try await cloud.api.deleteFirewallRule(ruleID) }
        }
        bind("cloudFirewallCreate", registry, reason: reason) { invocation in
            guard let json = invocation["path"]?.stringValue, let data = json.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sourceData = try? JSONSerialization.data(withJSONObject: value["source"] ?? [:]),
                  let destinationData = try? JSONSerialization.data(withJSONObject: value["destination"] ?? [:]),
                  let source = try? JSONDecoder().decode(CloudFirewallEndpoint.self, from: sourceData),
                  let destination = try? JSONDecoder().decode(CloudFirewallEndpoint.self, from: destinationData) else {
                throw ActionFailure(message: CloudStrings.ruleJSONRequired)
            }
            runTracked("create Cloud firewall rule", context) { _ = try await cloud.api.createFirewallRule(source: source, destination: destination, description: value["description"] as? String) }
        }
    }

    /// The network or rule id these actions take in `--path`; `missing`
    /// names which id and where to find one (not the file-path refusal).
    static func idArgument(_ invocation: ActionInvocation, _ missing: String) throws -> String {
        guard let value = invocation["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw ActionFailure(message: missing) }
        return value
    }
}
