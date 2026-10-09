import AppKit
import CmuxNextActions
import CmuxNextCloud

extension CloudHandlers {
    static func bindNetworkActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        let cloud = context.services.cloud
        bind("cloudTunnelAttach", registry, reason: reason) { invocation in
            let networkID = try networkArgument(invocation)
            runTracked("attach Cloud tunnel network", context) { try await cloud.api.attachTunnelNetwork(deviceFingerprint: cloud.localDeviceID(), networkID: networkID) }
        }
        bind("cloudTunnelDetach", registry, reason: reason) { invocation in
            let networkID = try networkArgument(invocation)
            runTracked("detach Cloud tunnel network", context) { try await cloud.api.detachTunnelNetwork(deviceFingerprint: cloud.localDeviceID(), networkID: networkID) }
        }
        bind("cloudTunnelRotateKey", registry, reason: reason) { invocation in
            guard let key = invocation["publicKey"]?.stringValue else { throw ActionFailure(message: CloudStrings.publicKeyRequired) }
            runTracked("rotate Cloud tunnel key", context) { _ = try await cloud.api.rotateTunnelKey(deviceFingerprint: cloud.localDeviceID(), publicKey: key) }
        }
        bind("cloudNetworkList", registry, reason: reason) { _ in
            runTracked("list Cloud networks", context) {
                let networks = try await cloud.api.listNetworks()
                let lines = networks.map { network in [network.id, "(\(network.scope))", network.cidr ?? ""].joined(separator: " ") }
                CloudPresenter.show(CloudStrings.networkTitle, lines.joined(separator: "\n"), copyable: true, in: window(context))
            }
        }
        bind("cloudFirewallList", registry, reason: reason) { _ in
            runTracked("list Cloud firewall rules", context) {
                let rules = try await cloud.api.listFirewallRules()
                CloudPresenter.show(CloudStrings.firewallTitle, rules.map { "\($0.id): \($0.description ?? $0.action)" }.joined(separator: "\n"), copyable: true, in: window(context))
            }
        }
        bind("cloudFirewallGet", registry, reason: reason) { invocation in
            let ruleID = try networkArgument(invocation)
            runTracked("get Cloud firewall rule", context) {
                let rule = try await cloud.api.getFirewallRule(ruleID)
                CloudPresenter.show(CloudStrings.firewallTitle, "\(rule.id): \(rule.description ?? rule.action)", copyable: true, in: window(context))
            }
        }
        bind("cloudFirewallDelete", registry, reason: reason) { invocation in
            let ruleID = try networkArgument(invocation)
            runTracked("delete Cloud firewall rule", context) { try await cloud.api.deleteFirewallRule(ruleID) }
        }
        bind("cloudFirewallCreate", registry, reason: reason) { invocation in
            guard let json = invocation["path"]?.stringValue, let data = json.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sourceData = try? JSONSerialization.data(withJSONObject: value["source"] ?? [:]),
                  let destinationData = try? JSONSerialization.data(withJSONObject: value["destination"] ?? [:]),
                  let source = try? JSONDecoder().decode(CloudFirewallEndpoint.self, from: sourceData),
                  let destination = try? JSONDecoder().decode(CloudFirewallEndpoint.self, from: destinationData) else {
                throw ActionFailure(message: "Pass path as JSON with source and destination firewall endpoints.")
            }
            runTracked("create Cloud firewall rule", context) { _ = try await cloud.api.createFirewallRule(source: source, destination: destination, description: value["description"] as? String) }
        }
    }

    private static func networkArgument(_ invocation: ActionInvocation) throws -> String {
        guard let value = invocation["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { throw ActionFailure(message: CloudStrings.filePathRequired) }
        return value
    }
}
