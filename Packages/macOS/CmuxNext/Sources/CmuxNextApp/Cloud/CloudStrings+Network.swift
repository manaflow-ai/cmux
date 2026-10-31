import Foundation

/// What the network, firewall, domain and publication actions say. Keys
/// live in Resources/Cloud.xcstrings with every app locale.
extension CloudStrings {
    /// `cloud tunnel-attach` / `tunnel-detach` without a network id. The
    /// actions take it in `--path` (their one string argument).
    static var networkIDRequired: String {
        String(localized: "cloud.network.networkIDRequired",
               defaultValue: "Pass the network id with --path <network-id>; `cmux cloud network-list` lists ids.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud firewall-get` / `firewall-delete` without a rule id.
    static var ruleIDRequired: String {
        String(localized: "cloud.network.ruleIDRequired",
               defaultValue: "Pass the firewall rule id with --path <rule-id>; `cmux cloud firewall-list` lists ids.",
               table: "Cloud", bundle: .module)
    }

    /// `cloud firewall-create` whose `--path` is not a rule: JSON with a
    /// source and a destination endpoint (`CloudFirewallEndpoint`).
    static var ruleJSONRequired: String {
        String(localized: "cloud.network.ruleJSONRequired",
               defaultValue: "Pass the rule as JSON with a source and a destination, for example --path '{\"source\":{\"vmId\":\"<machine-id>\"},\"destination\":{\"cidr\":\"10.0.0.0/24\",\"port\":443,\"protocol\":\"tcp\"}}'.",
               table: "Cloud", bundle: .module)
    }

    static var domainsTitle: String {
        String(localized: "cloud.result.domainsTitle", defaultValue: "Cloud Domains", table: "Cloud", bundle: .module)
    }

    static var publicationsTitle: String {
        String(localized: "cloud.result.publicationsTitle", defaultValue: "Cloud Publications", table: "Cloud", bundle: .module)
    }
}
