import Foundation

/// Resolves whether **presence-driven auto-attach** is enabled for this process.
///
/// When on, a signed-in phone with no paired Mac auto-connects to the freshest
/// online Mac discovered through the presence service (the dev worker in DEBUG),
/// giving a zero-setup dev experience: open the app, get connected, no QR.
///
/// Resolution order (first match wins):
///   1. Environment override `CMUX_PRESENCE_AUTO_ATTACH` ("1"/"true"/"on" vs else)
///   2. `UserDefaults` key `presenceAutoAttachEnabled`
///   3. Build default — **DEBUG = on, Release = OFF**
///
/// The Release-off default is the production-isolation gate: a shipped build
/// never auto-attaches from presence unless an operator explicitly opts in. This
/// mirrors the presence service URL resolution (DEBUG = dev worker, Release =
/// disabled) so dev and prod stay cleanly separated.
public struct MobilePresenceAutoAttachFlag: Sendable {
    public static let envKey = "CMUX_PRESENCE_AUTO_ATTACH"
    public static let defaultsKey = "presenceAutoAttachEnabled"

    public let isEnabled: Bool

    /// Production entry point: resolves from the process environment, standard
    /// `UserDefaults`, and the build type.
    public init() {
        self.init(environment: ProcessInfo.processInfo.environment)
    }

    /// Designated initializer (internal so its default args may reference
    /// internal symbols; exercised directly by `@testable` tests).
    init(
        environment: [String: String],
        defaults: UserDefaults? = .standard,
        isDebugBuild: Bool = MobilePresenceAutoAttachFlag.currentIsDebugBuild
    ) {
        if let raw = environment[Self.envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            isEnabled = Self.parseBool(raw)
        } else if let defaults, defaults.object(forKey: Self.defaultsKey) != nil {
            isEnabled = defaults.bool(forKey: Self.defaultsKey)
        } else {
            isEnabled = isDebugBuild
        }
    }

    static func parseBool(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    static var currentIsDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
