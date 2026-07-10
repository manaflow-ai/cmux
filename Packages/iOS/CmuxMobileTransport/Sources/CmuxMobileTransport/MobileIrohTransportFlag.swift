public import Foundation

/// Feature flag for the iOS iroh transport lane.
///
/// Resolution order is environment override, UserDefaults override, then build
/// flavor. DEBUG defaults on for dogfood and package tests; Release defaults
/// off until the rollout slice flips it.
public struct MobileIrohTransportFlag: Sendable, Equatable {
    /// Environment variable override for dogfood and tagged builds.
    public static let envKey = "CMUX_MOBILE_IROH_TRANSPORT"
    /// UserDefaults key for local dogfood toggles.
    public static let defaultsKey = "mobileIrohTransport"

    /// Whether iroh transport registration is enabled.
    public let isEnabled: Bool

    /// Creates a resolved flag.
    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Resolves the flag from environment, defaults, and build flavor.
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        isDebugBuild: Bool = MobileIrohTransportFlag.isDebugBuild
    ) -> MobileIrohTransportFlag {
        func parseBool(_ raw: String) -> Bool {
            switch raw.lowercased() {
            case "1", "true", "yes", "on": return true
            default: return false
            }
        }

        if let raw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return MobileIrohTransportFlag(isEnabled: parseBool(raw))
        }
        if defaults.object(forKey: defaultsKey) != nil {
            return MobileIrohTransportFlag(isEnabled: defaults.bool(forKey: defaultsKey))
        }
        return MobileIrohTransportFlag(isEnabled: isDebugBuild)
    }

    /// Compile-time build flavor, parameterized above for tests.
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
