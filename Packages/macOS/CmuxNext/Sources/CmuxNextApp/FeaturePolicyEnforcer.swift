import CmuxNextActions
import CmuxNextCompat
import CmuxNextWakeups
import Observation

/// `DisabledFeatures` beyond the action registry (spec/enterprise.md 5.2,
/// plans/cmux-next/enterprise.md P17-1b): the owning services refuse and
/// end the feature's live sessions on this Mac. Nothing remote stops: a
/// Cloud VM, an SSH host's daemon and its processes keep running.
@MainActor
struct FeaturePolicyEnforcer {
    let services: AppServices

    /// Follows the registry's disabled set, the current one now; the caller keeps the returned follower for the
    /// app's lifetime. `automation`: the device management profile (another process) changes the set.
    func start() -> AnyObject {
        let registry = services.registry
        let disabled = ServiceObservation(.automation, owner: "FeaturePolicyEnforcer", on: services.mainWork) {
            registry.disabledFeatures
        } apply: { [weak services] in if let services { Self.apply($0, to: services) } }
        return disabled
    }

    private static func apply(_ disabled: Set<ActionFeature>, to services: AppServices) {
        services.applyCloudPolicy(disabled: disabled.contains(.cloud))  // builds no CloudService
        services.madeSSH?.applyPolicy(disabled: disabled.contains(.remoteHosts))  // made later: `AppServices.ssh` applies it
        services.serverReach.applyPolicy(disabled: disabled.contains(.remoteHosts))
        services.apps.applyPolicy(disabled: disabled.contains(.apps))
    }
}
