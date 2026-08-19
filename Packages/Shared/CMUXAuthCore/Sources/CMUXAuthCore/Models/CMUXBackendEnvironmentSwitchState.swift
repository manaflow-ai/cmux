import Foundation

/// The runtime backend-environment switch surface a composition root hands to
/// Settings.
///
/// ``active`` is the environment the owning composition resolved when it was
/// built. The live switch transaction (sign out under the old environment,
/// quiesce the old graph, store the override, rebuild the composition) replaces
/// the whole root, so `active` converges to the user's choice by re-injection
/// from the new root; there is no pending/relaunch divergence left to display,
/// and the persisted override is written only by the transaction's commit
/// step, never by the picker directly. ``isPinnedByBuild`` reports that a
/// build-time override (`LocalConfig.plist` or a baked Info.plist value)
/// already decides a backend key, so the runtime override cannot steer this
/// build; the picker explains the pin instead.
public struct CMUXBackendEnvironmentSwitchState: Equatable, Sendable {
    /// The backend environment the owning composition root resolved.
    public let active: CMUXBackendEnvironmentOverride

    /// Whether `LocalConfig.plist` or a baked Info.plist value pins a backend
    /// key for this build, shadowing the runtime override (tagged dev builds).
    public let isPinnedByBuild: Bool

    /// Creates the switch state for one composition root.
    public init(
        active: CMUXBackendEnvironmentOverride,
        isPinnedByBuild: Bool
    ) {
        self.active = active
        self.isPinnedByBuild = isPinnedByBuild
    }
}
