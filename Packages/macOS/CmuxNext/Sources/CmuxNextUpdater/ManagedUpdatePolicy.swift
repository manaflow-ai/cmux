public import Foundation

/// The `DisableAutoUpdate` configuration-profile key the legacy app honors.
/// A profile targets the release domain `com.cmuxterm.app`; channel builds
/// also consult that domain so one profile governs every channel.
nonisolated public struct ManagedUpdatePolicy: Sendable {
    public static let key = "DisableAutoUpdate"
    public static let releaseDomain = "com.cmuxterm.app"
    /// `CMUX_DISABLE_AUTO_UPDATE=1` in the launch environment acts as a forced `DisableAutoUpdate`
    /// for that one process, without a profile: test harnesses that start a copy of an older build
    /// set it so the copy never downloads or installs a newer one.
    public static let environmentKey = "CMUX_DISABLE_AUTO_UPDATE"

    private let isForcedTrue: @Sendable () -> Bool

    public init(isForcedTrue: @escaping @Sendable () -> Bool) {
        self.isForcedTrue = isForcedTrue
    }

    /// Reads the launch environment, then forced values from the app's domain, then the release domain.
    public static func live(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> ManagedUpdatePolicy {
        let disabledByEnvironment = environment[environmentKey] == "1"
        return ManagedUpdatePolicy {
            if disabledByEnvironment || forced(in: .standard) { return true }
            guard bundleIdentifier != releaseDomain, let release = UserDefaults(suiteName: releaseDomain) else { return false }
            return forced(in: release)
        }
    }

    public var disablesUpdates: Bool { isForcedTrue() }

    private static func forced(in defaults: UserDefaults) -> Bool {
        defaults.objectIsForced(forKey: key) && defaults.bool(forKey: key)
    }
}
