public import Foundation

/// The `mobileDeviceListLocalFirst` feature flag (DESIGN.md §9). Same
/// DEBUG-on/Release-off seam as `PresenceServiceConfiguration`: an env override
/// wins (dogfood/tagged builds), then a UserDefaults override, then DEBUG → on /
/// Release → off. So production users keep today's registry-driven list until
/// dogfood approves flipping it, while DEBUG builds get local-first by default.
public enum MobileDeviceListLocalFirst {
    public static let envKey = "CMUX_MOBILE_DEVICE_LIST_LOCAL_FIRST"
    public static let defaultsKey = "mobileDeviceListLocalFirst"

    /// Whether the local-first device list is enabled for this process.
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        isDebugBuild: Bool = MobileDeviceListLocalFirst.isDebugBuild
    ) -> Bool {
        if let raw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return parseBool(raw)
        }
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        return isDebugBuild
    }

    /// Compile-time build flavor, parameterized above for testability.
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func parseBool(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }
}
