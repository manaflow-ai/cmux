public import CmuxNextActions

/// Socket methods outside the action registry that belong to a feature an
/// administrator can turn off (DisabledFeatures, plans/cmux-next/enterprise.md
/// P17-1b). Phone access (`mobile.*`) is not Cloud: the phone reaches this Mac.
extension ControlMethod {
    /// The feature `method` belongs to, or nil.
    public static func policyFeature(of method: String) -> ActionFeature? {
        switch method {
        // A new sandboxed run is Cloud; waiting on or cancelling one that exists is its cleanup.
        // `auth.token` hands a Cloud token outside the app: off with Cloud.
        case "auth.token", "cloud.machines", "cloud.automation", "debug.cloud.link_ensure", "runs.sandbox.create", "vm.agent_key.create": return .cloud
        case "remote.machines": return .remoteHosts
        default:
            // CodeRouter writes configure the Cloud model plane; its reads stay.
            guard method.hasPrefix("coderouter."), let verb = method.split(separator: ".").last else { return nil }
            return ["add", "set", "update", "remove", "clear"].contains(String(verb)) ? .cloud : nil
        }
    }

    /// `feature.disabled` when `method`'s feature is in `disabled`.
    public static func policyRefusal(_ method: String, disabled: Set<ActionFeature>) -> ControlError? {
        guard let feature = policyFeature(of: method), disabled.contains(feature) else { return nil }
        return ControlError.featureDisabled(method, feature: feature.rawValue)
    }
}
