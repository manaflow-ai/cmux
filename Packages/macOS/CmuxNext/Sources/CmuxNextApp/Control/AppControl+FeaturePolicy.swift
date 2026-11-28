import CmuxNextActions
import CmuxNextControl

/// Socket methods outside the action registry that belong to a feature an
/// administrator can turn off (DisabledFeatures, plans/cmux-next/enterprise.md
/// P17-1b). Phone access (`mobile.*`) is not Cloud: the phone reaches this Mac.
extension AppControl {
    /// The feature `method` belongs to, or nil.
    nonisolated static func policyFeature(of method: String) -> ActionFeature? {
        switch method {
        case "cloud.machines": return .cloud
        case "remote.machines": return .remoteHosts
        default:
            // CodeRouter writes configure the Cloud model plane; its reads stay.
            guard method.hasPrefix("coderouter."), let verb = method.split(separator: ".").last else { return nil }
            return ["add", "set", "update", "remove", "clear"].contains(String(verb)) ? .cloud : nil
        }
    }

    /// `feature.disabled` when `method`'s feature is in `disabled`.
    nonisolated static func policyRefusal(_ method: String, disabled: Set<ActionFeature>) -> ControlError? {
        guard let feature = policyFeature(of: method), disabled.contains(feature) else { return nil }
        return ControlError.featureDisabled(method, feature: feature.rawValue)
    }
}
