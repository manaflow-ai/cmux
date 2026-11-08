import CmuxCloud
import CmuxSettings
import Foundation

/// The Cloud availability answers used by app entry points. Cloud no longer
/// depends on the PostHog rollout payload; only managed policy and the local
/// first-use activation setting participate in these production gates.
extension CloudMachinesFeature {
    /// Whether Cloud can be discovered on this Mac. This is the managed-policy
    /// decision; it intentionally does not include the local
    /// activation marker so the Cloud tab can host first-use enablement.
    @MainActor static var isAvailable: Bool {
        isAvailable(policy: ManagedDevicePolicy())
    }

    /// Off-main mirror of ``isAvailable`` for right-sidebar mode resolution.
    nonisolated static func offMainIsAvailable() -> Bool {
        isAvailable(policy: ManagedDevicePolicy())
    }

    @MainActor static var isEnabled: Bool {
        isEnabled(defaults: .standard, policy: ManagedDevicePolicy())
    }

    /// The same answer from any isolation (right-sidebar mode availability,
    /// the activation policy).
    nonisolated static func offMainIsEnabled(defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults: defaults, policy: ManagedDevicePolicy(defaults: defaults))
    }
}
