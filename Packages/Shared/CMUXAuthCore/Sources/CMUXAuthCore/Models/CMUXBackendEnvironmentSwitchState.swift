import Foundation

/// The runtime backend-environment switch surface a composition root hands to
/// Settings.
///
/// ``active`` is the environment THIS process resolved at startup; ``pending``
/// is the persisted override the NEXT launch will read. They diverge after the
/// user flips the picker, and Settings shows a persistent relaunch notice until
/// the app is closed and reopened (iOS apps must not self-terminate).
/// ``isPinnedByBuild`` reports that a build-time override (`LocalConfig.plist`
/// or a baked Info.plist value) already decides a backend key, so the runtime
/// override cannot steer this build; the picker explains the pin instead.
public struct CMUXBackendEnvironmentSwitchState: Sendable {
    /// `UserDefaults` is documented thread-safe and the reference is immutable
    /// here; the wrapper only carries it across SwiftUI's environment copies.
    private struct DefaultsReference: @unchecked Sendable {
        let defaults: UserDefaults
    }

    /// The backend environment this process resolved at startup.
    public let active: CMUXBackendEnvironmentOverride

    /// Whether `LocalConfig.plist` or a baked Info.plist value pins a backend
    /// key for this build, shadowing the runtime override (tagged dev builds).
    public let isPinnedByBuild: Bool

    private let store: DefaultsReference

    /// Creates the switch state over the same defaults the composition root
    /// resolved the override from, so Settings reads and writes the exact
    /// value the next launch applies.
    public init(
        active: CMUXBackendEnvironmentOverride,
        isPinnedByBuild: Bool,
        defaults: UserDefaults
    ) {
        self.active = active
        self.isPinnedByBuild = isPinnedByBuild
        self.store = DefaultsReference(defaults: defaults)
    }

    /// The persisted override the next launch will read.
    public var pending: CMUXBackendEnvironmentOverride {
        CMUXBackendEnvironmentOverride.load(from: store.defaults)
    }

    /// Persist the override the next launch should apply. Does not change
    /// ``active``: the running process keeps its startup resolution.
    public func setPending(_ overrideValue: CMUXBackendEnvironmentOverride) {
        overrideValue.store(in: store.defaults)
    }
}
