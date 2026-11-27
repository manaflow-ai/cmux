public import Foundation

/// The `mobilePairedMacBackup` feature flag. Same DEBUG-on/Release-off seam as
/// ``MobileDeviceListLocalFirst`` / ``PresenceClient/resolvedServiceBaseURL``:
/// an env override wins (dogfood/tagged builds), then a UserDefaults override,
/// then DEBUG → on / Release → off.
///
/// When enabled, the iOS app mirrors its local paired-Mac store to the per-team
/// Durable Object (scoped to the signed-in user) and restores it on sign-in, so
/// saved hosts and their IPs — including manually typed ones — survive an app
/// upgrade, a bundle-id change, or a reinstall. Off in Release until dogfood
/// approves flipping it, so production users are unaffected.
public struct MobilePairedMacBackup: Sendable, Equatable {
    /// Environment variable override for dogfood and tagged builds.
    public static let envKey = "CMUX_MOBILE_PAIRED_MAC_BACKUP"
    /// UserDefaults key for local dogfood toggles.
    public static let defaultsKey = "mobilePairedMacBackup"

    /// Whether paired-Mac backup/restore is enabled for this process.
    public let isEnabled: Bool

    /// Create a resolved paired-Mac backup flag value.
    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Resolve the flag from the environment override, then a UserDefaults
    /// override, then the build flavor (DEBUG on / Release off).
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        isDebugBuild: Bool = MobilePairedMacBackup.isDebugBuild
    ) -> MobilePairedMacBackup {
        func parseBool(_ raw: String) -> Bool {
            switch raw.lowercased() {
            case "1", "true", "yes", "on": return true
            default: return false
            }
        }

        if let raw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return MobilePairedMacBackup(isEnabled: parseBool(raw))
        }
        if defaults.object(forKey: defaultsKey) != nil {
            return MobilePairedMacBackup(isEnabled: defaults.bool(forKey: defaultsKey))
        }
        return MobilePairedMacBackup(isEnabled: isDebugBuild)
    }

    /// Compile-time build flavor, parameterized above for testability.
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
