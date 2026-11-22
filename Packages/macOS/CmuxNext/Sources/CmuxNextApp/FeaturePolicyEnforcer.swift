import CmuxNextActions
import Observation

/// `DisabledFeatures` beyond the action registry (spec/enterprise.md 5.2,
/// plans/cmux-next/enterprise.md P17-1b): the owning services refuse and
/// end the feature's live sessions on this Mac. Nothing remote stops: a
/// Cloud VM, an SSH host's daemon and its processes keep running.
@MainActor
struct FeaturePolicyEnforcer {
    let services: AppServices

    /// Follows the registry's disabled set for the app's lifetime.
    func start() {
        let registry = services.registry
        apply(registry.disabledFeatures, to: services)
        // task-owner: app-lifetime observation of the managed policy; ends with the process
        Task { [weak services] in
            for await disabled in Observations({ registry.disabledFeatures }) {
                guard let services else { return }
                apply(disabled, to: services)
            }
        }
    }

    private func apply(_ disabled: Set<ActionFeature>, to services: AppServices) {
        services.cloud.applyPolicy(disabled: disabled.contains(.cloud))
        services.ssh.applyPolicy(disabled: disabled.contains(.remoteHosts))
        services.serverReach.applyPolicy(disabled: disabled.contains(.remoteHosts))
        services.apps.applyPolicy(disabled: disabled.contains(.apps))
    }
}
