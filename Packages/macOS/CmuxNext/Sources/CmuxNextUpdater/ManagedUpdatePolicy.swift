public import Foundation

/// The `DisableAutoUpdate` configuration-profile key the legacy app honors.
/// A profile targets the release domain `com.cmuxterm.app`; channel builds
/// also consult that domain so one profile governs every channel.
nonisolated public struct ManagedUpdatePolicy: Sendable {
    public static let key = "DisableAutoUpdate"
    public static let releaseDomain = "com.cmuxterm.app"

    private let isForcedTrue: @Sendable () -> Bool

    public init(isForcedTrue: @escaping @Sendable () -> Bool) {
        self.isForcedTrue = isForcedTrue
    }

    /// Reads forced values from the app's domain, then the release domain.
    public static func live(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> ManagedUpdatePolicy {
        ManagedUpdatePolicy {
            if forced(in: .standard) { return true }
            guard bundleIdentifier != releaseDomain, let release = UserDefaults(suiteName: releaseDomain) else { return false }
            return forced(in: release)
        }
    }

    public var disablesUpdates: Bool { isForcedTrue() }

    private static func forced(in defaults: UserDefaults) -> Bool {
        defaults.objectIsForced(forKey: key) && defaults.bool(forKey: key)
    }
}
