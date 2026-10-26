public import Foundation

/// The managed-policy key that turns the flags fetch off, read like `DisableAutoUpdate`
/// (``ManagedUpdatePolicy``): forced in the app's domain or the release domain.
nonisolated public struct FlagsFetchPolicy: Sendable {
    public static let key = "DisableRemoteFeatureFlags"

    private let isForcedTrue: @Sendable () -> Bool

    public init(isForcedTrue: @escaping @Sendable () -> Bool) {
        self.isForcedTrue = isForcedTrue
    }

    public static func live(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> FlagsFetchPolicy {
        FlagsFetchPolicy {
            if forced(in: .standard) { return true }
            guard bundleIdentifier != ManagedUpdatePolicy.releaseDomain,
                  let release = UserDefaults(suiteName: ManagedUpdatePolicy.releaseDomain) else { return false }
            return forced(in: release)
        }
    }

    public var disablesFetch: Bool { isForcedTrue() }

    private static func forced(in defaults: UserDefaults) -> Bool {
        defaults.objectIsForced(forKey: key) && defaults.bool(forKey: key)
    }
}
