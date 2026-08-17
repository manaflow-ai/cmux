public import Foundation

/// The `mobileDeviceListLocalFirst` feature flag (DESIGN.md §9). The durable
/// sync projection is the default in every build so a signed-out Mac cannot be
/// resurrected by the legacy paired-Mac fallback. An environment or
/// UserDefaults override remains available as an operational kill switch while
/// the rollout is monitored.
///
/// Modeled as an instantiable resolved value (not a static namespace): construct
/// one via ``resolved(environment:defaults:isDebugBuild:)`` at the composition
/// root and read ``isEnabled``.
public struct MobileDeviceListLocalFirst: Sendable, Equatable {
    public static let envKey = "CMUX_MOBILE_DEVICE_LIST_LOCAL_FIRST"
    public static let defaultsKey = "mobileDeviceListLocalFirst"

    /// Whether the local-first device list is enabled for this process.
    public let isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Resolve the flag from the environment override, then a UserDefaults
    /// override, then the always-on product default. `isDebugBuild` remains a
    /// parameter for source compatibility with existing callers and tests.
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        isDebugBuild: Bool = MobileDeviceListLocalFirst.isDebugBuild
    ) -> MobileDeviceListLocalFirst {
        if let raw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return MobileDeviceListLocalFirst(isEnabled: parseBool(raw))
        }
        if defaults.object(forKey: defaultsKey) != nil {
            return MobileDeviceListLocalFirst(isEnabled: defaults.bool(forKey: defaultsKey))
        }
        _ = isDebugBuild
        return MobileDeviceListLocalFirst(isEnabled: true)
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
