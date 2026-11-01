public import CmuxNextActions

/// Socket methods outside the action registry that belong to a feature an
/// administrator can turn off (DisabledFeatures, plans/cmux-next/enterprise.md
/// P17-1b). Phone access (`mobile.*`) is not Cloud: the phone reaches this Mac.
/// Actions get the same refusal from the registry (``RegistryControlBridge``).
extension ActionFeature {
    /// The feature control method `method` belongs to, or nil.
    public init?(controlMethod method: String) {
        switch method {
        // A new sandboxed run is Cloud; waiting on or cancelling one that exists is its cleanup.
        case "auth.token", "cloud.machines", "cloud.automation", "debug.cloud.link_ensure", "runs.sandbox.create", "vm.agent_key.create": self = .cloud
        case "remote.machines": self = .remoteHosts
        default:
            // CodeRouter writes configure the Cloud model plane; its reads stay.
            guard method.hasPrefix("coderouter."), let verb = method.split(separator: ".").last,
                  ["add", "set", "update", "remove", "clear"].contains(String(verb)) else { return nil }
            self = .cloud
        }
    }
}

extension ControlError {
    /// `feature.disabled` when control method `method`'s feature is in `disabled`, else nil.
    public static func policyRefusal(_ method: String, disabled: Set<ActionFeature>) -> ControlError? {
        guard let feature = ActionFeature(controlMethod: method), disabled.contains(feature) else { return nil }
        return featureDisabled(method, feature: feature.rawValue)
    }
}
