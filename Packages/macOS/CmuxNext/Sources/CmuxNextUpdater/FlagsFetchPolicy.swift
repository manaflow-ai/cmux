public import CmuxNextSettings

/// The managed policy `DisableRemoteFeatureFlags`, forced in the managed domain
/// (`com.manaflow.cmux`): no signed feature document is fetched, and a stored one
/// does not apply. The App reads it from `SettingsController.managedPolicy`, the
/// one reader, and sets ``UpdaterService/remoteFeatureFlagsPolicy`` before
/// ``UpdaterService/start()``. Chrome's matching policy is `ChromeVariations`
/// (components/variations/service/variations_service.cc, `IsFetchingEnabled`).
nonisolated public struct FlagsFetchPolicy: Sendable, Equatable {
    public static let key = ManagedPreferences.disableRemoteFeatureFlagsKey
    public static let enabled = FlagsFetchPolicy(disablesRemoteFlags: false)

    public let disablesRemoteFlags: Bool

    public init(disablesRemoteFlags: Bool) {
        self.disablesRemoteFlags = disablesRemoteFlags
    }

    /// From the forced managed values (`SettingsController.managedPolicy`); only a boolean true turns it on.
    public init(managedPolicy: [String: JSONValue]) {
        self.init(disablesRemoteFlags: managedPolicy[Self.key]?.boolValue == true)
    }
}
